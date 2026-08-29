#!/usr/bin/env bb

(ns test-agents-cli
  (:require [babashka.fs :as fs]
            [babashka.process :as p]
            [cheshire.core :as json]
            [clojure.string :as str]
            [clojure.test :refer [deftest is run-tests testing]]))

(def ^:private cli-dir (fs/parent (fs/absolutize *file*)))
(def ^:private cli-path (str (fs/path cli-dir "agents-cli")))
(def ^:private skipped-integration-cases (atom []))

(defn- default-manager-root []
  (fs/path (System/getProperty "user.home") "code" "projects"
           "workstream-manager"))

(defn- manager-root []
  (let [configured-root (some-> (System/getenv "WORKSTREAM_MANAGER_ROOT")
                                str/trim)]
    (if (seq configured-root)
      (fs/path configured-root)
      (default-manager-root))))

(defn- skip-integration! [case-name]
  (swap! skipped-integration-cases conj case-name))

(defn- integrations-required? []
  (= "1" (System/getenv "AGENTS_REQUIRE_TOOLS")))

(defn- run-process!
  ([args]
   (run-process! args {}))
  ([args options]
   (let [{:keys [exit out err]}
         @(p/process args (merge {:out :string :err :string} options))]
     {:exit exit :out out :err err})))

(defn- require-success [label {:keys [exit err] :as result}]
  (when-not (zero? exit)
    (throw (ex-info (str label " failed: " err) result)))
  result)

(defn- require-cli-success [label {:keys [exit err json] :as result}]
  (when-not (zero? exit)
    (throw (ex-info (str label " failed"
                         "\nstderr: " (pr-str err)
                         "\nenvelope: " (pr-str json))
                    result)))
  result)

(defn- run-cli-at-with-manager! [script root & args]
  (let [environment (assoc (into {} (System/getenv))
                           "WORKSTREAM_MANAGER_ROOT" (str root))
        {:keys [out] :as result}
        (run-process! (into [script] args) {:env environment})]
    (is (re-matches #"[^\r\n]+(?:\r?\n)?" out)
        (str "stdout must be exactly one JSON line, got " (pr-str out)))
    (assoc result :json (json/parse-string (str/trim out) true))))

(defn- run-cli-at! [script & args]
  (apply run-cli-at-with-manager! script (manager-root) args))

(defn- run-cli! [& args]
  (apply run-cli-at! cli-path args))

(defn- manager-checkout-available? [root]
  (fs/regular-file? (fs/path root "src" "wsm" "cli.clj")))

(defmacro ^{:private true :clj-kondo/lint-as 'clojure.test/deftest}
  deftest-with-manager [name & body]
  `(deftest ~name
     (if (manager-checkout-available? (manager-root))
       (do ~@body)
       (skip-integration! ~(str name)))))

(defn- cleanup! [root]
  (try
    (fs/delete-tree root)
    (catch Exception _ nil)))

(defn- fresh-jj-project! []
  (let [root (fs/create-temp-dir)
        project (str (fs/path root "project"))]
    (require-success "jj init"
                     (run-process! ["jj" "--quiet" "git" "init" project]))
    (spit (str (fs/path project "seed.txt")) "seed\n")
    (require-success "jj seed commit"
                     (run-process! ["jj" "-R" project "commit" "-m" "seed"]))
    (require-success "jj main bookmark"
                     (run-process! ["jj" "-R" project "bookmark" "create"
                                    "main" "-r" "@-"]))
    {:root root :project project}))

(defn- run-git! [dir & args]
  (run-process! (into ["git"] args) {:dir dir}))

(defn- fresh-git-project! []
  (let [root (fs/canonicalize (fs/create-temp-dir))
        project (str (fs/path root "project"))]
    (require-success "git init"
                     (run-process! ["git" "init" "-q" "-b" "main" project]))
    (doseq [[key value] [["user.name" "Agents CLI test"]
                         ["user.email" "agents-cli@example.invalid"]
                         ["commit.gpgsign" "false"]
                         ["rerere.enabled" "false"]]]
      (require-success (str "git config " key)
                       (run-git! project "config" key value)))
    (spit (str (fs/path project "seed.txt")) "seed\n")
    (require-success "git add seed" (run-git! project "add" "-A"))
    (require-success "git seed commit"
                     (run-git! project "commit" "-q" "-m" "seed"))
    {:root root :project project}))

(defn- git-line! [dir & args]
  (let [result (apply run-git! dir args)]
    (-> (require-success (str "git " (str/join " " args)) result)
        :out
        str/trim)))

(deftest wrapper-contract-and-packaged-layout-test
  (testing "repository and copied scripts resolve workstream-manager from WORKSTREAM_MANAGER_ROOT"
    (if (manager-checkout-available? (manager-root))
      (let [root (fs/create-temp-dir)]
        (try
          (let [packaged-cli (str (fs/path root "agents-cli"))]
            (fs/copy cli-path packaged-cli)
            (.setExecutable (java.io.File. packaged-cli) true)
            (doseq [[label script] [["repository" cli-path]
                                    ["copied script" packaged-cli]]]
              (testing label
                (let [{:keys [exit json]}
                      (run-cli-at-with-manager! script (manager-root)
                                                "not-a-command")]
                  (is (= 1 exit))
                  (is (false? (:ok json)))
                  (is (= "bad-args" (get-in json [:error :code])))
                  (is (string? (get-in json [:error :message])))))))
          (finally
            (cleanup! root))))
      (skip-integration!
       "wrapper-contract-and-packaged-layout-test / packaged layout")))
  (testing "a missing local dependency emits one JSON error envelope"
    (let [root (fs/create-temp-dir)]
      (try
        (let [missing-root (fs/path root "missing-workstream-manager")
              {:keys [exit json]}
              (run-cli-at-with-manager! cli-path missing-root "not-a-command")]
          (is (= 1 exit))
          (is (false? (:ok json)))
          (is (= "dependency-unavailable" (get-in json [:error :code])))
          (is (str/includes? (get-in json [:error :message])
                             (str missing-root))))
        (finally
          (cleanup! root))))))

(deftest wrapper-error-envelope-isolation-test
  (let [root (fs/create-temp-dir)]
    (try
      (let [missing-root (str (fs/path root "missing"))
            copied (str (fs/path root "agents-cli"))
            manager (str (fs/path root "manager"))
            source (fs/path manager "src" "wsm")]
        (fs/copy cli-path copied)
        (.setExecutable (java.io.File. copied) true)
        (doseq [[label script] [["repository" cli-path] ["copied" copied]]]
          (testing (str label " missing dependency")
            (let [{:keys [exit out err] :as result}
                  (run-process! [script "not-a-command"]
                                {:env (assoc (into {} (System/getenv))
                                             "WORKSTREAM_MANAGER_ROOT" missing-root)})]
              (is (= 1 exit))
              (is (re-matches #"[^\r\n]+\r?\n" out))
              (is (not (re-find #"(?m)Exception|AssertionError|at " err)))
              (is (= "dependency-unavailable"
                     (get-in (assoc result :json
                                    (json/parse-string (str/trim out) true))
                             [:json :error :code]))))))
        (fs/create-dirs source)
        (spit (str (fs/path source "cli.clj"))
              "(ns wsm.cli)\n(defn -main [_] (throw (AssertionError. \"boom\")))\n")
        (let [{:keys [exit out err]}
              (run-process! [cli-path "not-a-command"]
                            {:env (assoc (into {} (System/getenv))
                                         "WORKSTREAM_MANAGER_ROOT" manager)})]
          (is (= 1 exit))
          (is (re-matches #"[^\r\n]+\r?\n" out))
          (is (not (re-find #"(?m)Exception|AssertionError|at " err)))
          (is (= "dependency-unavailable"
                 (get-in (json/parse-string (str/trim out) true) [:error :code])))))
      (finally
        (cleanup! root)))))

(deftest-with-manager default-manager-root-fallback-test
  (let [root (fs/create-temp-dir)
        home (fs/path root "home")
        fallback-root (fs/path home "code" "projects"
                               "workstream-manager")]
    (try
      (fs/create-dirs (fs/parent fallback-root))
      (fs/create-sym-link fallback-root (manager-root))
      (doseq [[label environment]
              [["unset" (dissoc (into {} (System/getenv))
                                "WORKSTREAM_MANAGER_ROOT")]
               ["whitespace" (assoc (into {} (System/getenv))
                                    "WORKSTREAM_MANAGER_ROOT" "  ")]]]
        (testing label
          (let [{:keys [exit out]}
                (run-process! ["bb" (str "-Duser.home=" home) cli-path
                               "not-a-command"]
                              {:env environment})
                envelope (json/parse-string (str/trim out) true)]
            (is (= 1 exit))
            (is (= "bad-args" (get-in envelope [:error :code]))))))
      (finally
        (cleanup! root)))))

(deftest-with-manager jj-consumer-flow-test
  (testing "the wrapper creates, previews, and lands a representative jj workspace"
    (let [{:keys [root project]} (fresh-jj-project!)]
      (try
        (let [{:keys [exit json]}
              (require-cli-success
               "workspace-add jj consumer"
               (run-cli! "workspace-add" "--project" project
                         "--name" "jj-consumer"))
              workspace (:workspace json)
              workspace-dir (:path workspace)]
          (is (= 0 exit))
          (is (= "jj" (:vcs workspace)))
          (is (= "agents/jj-consumer" (:jj_name workspace)))
          (spit (str (fs/path workspace-dir "consumer.txt")) "jj consumer\n")
          (require-success "jj consumer commit"
                           (run-process! ["jj" "-R" workspace-dir "commit"
                                          "-m" "jj consumer change"]))
          (let [{preview-exit :exit preview-json :json}
                (require-cli-success
                 "workspace-land-preview jj consumer"
                 (run-cli! "workspace-land-preview" "--project" project
                           "--name" "jj-consumer"))
                preview (:preview preview-json)
                target-snapshot (:target_snapshot preview)]
            (is (= 0 preview-exit))
            (is (= "jj" (:vcs preview)))
            (is (= ["jj consumer change"] (mapv :subject (:commits preview))))
            (is (= [] (:conflicts preview)))
            (is (false? (:needs_message preview)))
            (is (seq target-snapshot))
            (let [{land-exit :exit land-json :json}
                  (require-cli-success
                   "workspace-land jj consumer"
                   (run-cli! "workspace-land" "--project" project
                             "--name" "jj-consumer"
                             "--expected-snapshot" target-snapshot
                             "--finalize-quiesced"))
                  rebase-result
                  (require-cli-success "rebase-onto-trunk jj consumer"
                                       (run-cli! "rebase-onto-trunk" "--project" project))
                  show-result
                  (run-process!
                   ["jj" "--ignore-working-copy" "--no-pager" "-R" project
                    "file" "show" "-r" "main" "root:\"consumer.txt\""])
                  shown (:out (require-success "jj show landed file" show-result))
                  workspace-list-out
                  (:out (require-success
                         "jj workspace list after finalized land"
                         (run-process! ["jj" "--ignore-working-copy" "--no-pager"
                                        "-R" project "workspace" "list"])))]
              (is (= 0 land-exit))
              (is (= 0 (:exit rebase-result)))
              (is (= 0 (get-in rebase-result [:json :rebased :count])))
              (is (true? (:ok land-json)))
              (is (false? (get-in land-json [:landed :workspace_retained])))
              (is (not (str/includes? workspace-list-out "agents/jj-consumer")))
              (is (= "jj consumer\n" shown)))))
        (finally
          (cleanup! root))))))

(deftest-with-manager git-consumer-flow-test
  (testing "the wrapper creates, previews, and lands a representative git worktree"
    (let [{:keys [root project]} (fresh-git-project!)]
      (try
        (let [{:keys [exit json]}
              (require-cli-success
               "workspace-add git consumer"
               (run-cli! "workspace-add" "--project" project
                         "--name" "git-consumer"))
              workspace (:workspace json)
              workspace-dir (:path workspace)]
          (is (= 0 exit))
          (is (= "git" (:vcs workspace)))
          (is (= "agents/git-consumer" (:branch workspace)))
          (spit (str (fs/path workspace-dir "consumer.txt")) "git consumer\n")
          (require-success "git add consumer change"
                           (run-git! workspace-dir "add" "-A"))
          (require-success "git consumer commit"
                           (run-git! workspace-dir "commit" "-q" "-m"
                                     "git consumer change"))
          (let [{preview-exit :exit preview-json :json}
                (require-cli-success
                 "workspace-land-preview git consumer"
                 (run-cli! "workspace-land-preview" "--project" project
                           "--name" "git-consumer"))
                preview (:preview preview-json)
                target-snapshot (:target_snapshot preview)]
            (is (= 0 preview-exit))
            (is (= "git" (:vcs preview)))
            (is (= ["git consumer change"] (mapv :subject (:commits preview))))
            (is (= [] (:conflicts preview)))
            (is (false? (:needs_message preview)))
            (is (seq target-snapshot))
            (let [{land-exit :exit land-json :json}
                  (require-cli-success
                   "workspace-land git consumer"
                   (run-cli! "workspace-land" "--project" project
                             "--name" "git-consumer"
                             "--expected-snapshot" target-snapshot
                             "--finalize-quiesced"))
                  rebase-result
                  (require-cli-success "rebase-onto-trunk git consumer"
                                       (run-cli! "rebase-onto-trunk" "--project" project))
                  worktree-list-out
                  (:out (require-success
                         "git worktree list after finalized land"
                         (run-git! project "worktree" "list" "--porcelain")))
                  branch-list-out
                  (:out (require-success
                         "git branch list after finalized land"
                         (run-git! project "branch" "--list" "agents/git-consumer")))]
              (is (= 0 land-exit))
              (is (= 0 (:exit rebase-result)))
              (is (= 0 (get-in rebase-result [:json :rebased :count])))
              (is (true? (:ok land-json)))
              (is (false? (get-in land-json [:landed :workspace_retained])))
              (is (not (str/includes? worktree-list-out workspace-dir)))
              (is (str/blank? branch-list-out))
              (is (= (get-in land-json [:landed :commit_id])
                     (git-line! project "rev-parse" "main")))
              (is (= "git consumer\n"
                     (:out (require-success
                            "git show landed file"
                            (run-git! project "show" "main:consumer.txt"))))))))
        (finally
          (cleanup! root))))))

(deftest-with-manager git-conflict-payload-test
  (testing "git preview decodes a conflicted path with spaces as a file payload"
    (let [{:keys [root project]} (fresh-git-project!)]
      (try
        (spit (str (fs/path project "conflict path.txt")) "base\n")
        (require-success "git add conflict fixture" (run-git! project "add" "-A"))
        (require-success "git commit conflict fixture"
                         (run-git! project "commit" "-q" "-m" "conflict fixture"))
        (let [add (require-cli-success
                   "workspace-add git conflict"
                   (run-cli! "workspace-add" "--project" project
                             "--name" "git-conflict"))
              workspace-dir (get-in add [:json :workspace :path])]
          (is (= 0 (:exit add)))
          (spit (str (fs/path workspace-dir "conflict path.txt")) "session\n")
          (require-success "git commit session conflict"
                           (run-git! workspace-dir "commit" "-q" "-am"
                                     "session conflict"))
          (spit (str (fs/path project "conflict path.txt")) "trunk\n")
          (require-success "git commit trunk conflict"
                           (run-git! project "commit" "-q" "-am"
                                     "trunk conflict"))
          (let [{:keys [exit json]}
                (require-cli-success
                 "workspace-land-preview git conflict"
                 (run-cli! "workspace-land-preview" "--project" project
                           "--name" "git-conflict"))]
            (is (= 0 exit))
            (is (= [{:file "conflict path.txt"}]
                   (get-in json [:preview :conflicts])))))
        (finally
          (cleanup! root))))))

(deftest-with-manager jj-guarded-forget-refuses-changed-workspace-test
  (testing "workspace-forget --if-unchanged refuses a jj workspace with addable changes"
    (let [{:keys [root project]} (fresh-jj-project!)]
      (try
        (let [{:keys [json]}
              (require-cli-success
               "workspace-add jj guarded-forget"
               (run-cli! "workspace-add" "--project" project
                         "--name" "jj-guarded-forget"))
              workspace-dir (get-in json [:workspace :path])]
          (spit (str (fs/path workspace-dir "session.txt")) "session change\n")
          (require-success "jj session commit"
                           (run-process! ["jj" "-R" workspace-dir "commit"
                                          "-m" "session change"]))
          (let [{:keys [exit json]}
                (run-cli! "workspace-forget" "--project" project
                          "--name" "jj-guarded-forget"
                          "--if-unchanged" "--create-trunk" "main")
                list-out
                (:out (require-success
                       "jj workspace list after refused forget"
                       (run-process! ["jj" "--ignore-working-copy" "--no-pager"
                                      "-R" project "workspace" "list"])))]
            (is (= 1 exit))
            (is (false? (:ok json)))
            (is (= "workspace-changed" (get-in json [:error :code])))
            (is (str/includes? list-out "agents/jj-guarded-forget"))
            (is (fs/exists? (fs/path workspace-dir "session.txt"))))
          (let [{:keys [exit json]}
                (require-cli-success
                 "workspace-forget jj guarded-forget"
                 (run-cli! "workspace-forget" "--project" project
                           "--name" "jj-guarded-forget"))
                list-out
                (:out (require-success
                       "jj workspace list after forget"
                       (run-process! ["jj" "--ignore-working-copy" "--no-pager"
                                      "-R" project "workspace" "list"])))]
            (is (= 0 exit))
            (is (true? (:ok json)))
            (is (not (str/includes? list-out "agents/jj-guarded-forget")))))
        (finally
          (cleanup! root))))))

(deftest-with-manager git-guarded-forget-refuses-changed-workspace-test
  (testing "workspace-forget --if-unchanged refuses a git worktree with addable changes"
    (let [{:keys [root project]} (fresh-git-project!)]
      (try
        (let [{:keys [json]}
              (require-cli-success
               "workspace-add git guarded-forget"
               (run-cli! "workspace-add" "--project" project
                         "--name" "git-guarded-forget"))
              workspace-dir (get-in json [:workspace :path])]
          (spit (str (fs/path workspace-dir "session.txt")) "session change\n")
          (require-success "git add session change"
                           (run-git! workspace-dir "add" "-A"))
          (require-success "git session commit"
                           (run-git! workspace-dir "commit" "-q" "-m"
                                     "session change"))
          (let [{:keys [exit json]}
                (run-cli! "workspace-forget" "--project" project
                          "--name" "git-guarded-forget"
                          "--if-unchanged" "--create-trunk" "main")
                list-out
                (:out (require-success
                       "git worktree list after refused forget"
                       (run-git! project "worktree" "list" "--porcelain")))]
            (is (= 1 exit))
            (is (false? (:ok json)))
            (is (= "workspace-changed" (get-in json [:error :code])))
            (is (str/includes? list-out workspace-dir))
            (is (fs/exists? (fs/path workspace-dir "session.txt"))))
          (let [{:keys [exit json]}
                (require-cli-success
                 "workspace-forget git guarded-forget"
                 (run-cli! "workspace-forget" "--project" project
                           "--name" "git-guarded-forget"))
                list-out
                (:out (require-success
                       "git worktree list after forget"
                       (run-git! project "worktree" "list" "--porcelain")))]
            (is (= 0 exit))
            (is (true? (:ok json)))
            (is (not (str/includes? list-out workspace-dir)))))
        (finally
          (cleanup! root))))))

(deftest-with-manager jj-stale-snapshot-land-refused-then-recovers-test
  (testing "workspace-land refuses a stale --expected-snapshot then succeeds with a fresh one"
    (let [{:keys [root project]} (fresh-jj-project!)]
      (try
        (let [{:keys [json]}
              (require-cli-success
               "workspace-add jj stale-snapshot"
               (run-cli! "workspace-add" "--project" project
                         "--name" "jj-stale"))
              workspace-dir (get-in json [:workspace :path])
              main-commit-id
              (fn []
                (str/trim
                 (:out (require-success
                        "jj main commit id"
                        (run-process! ["jj" "--ignore-working-copy" "--no-pager"
                                       "-R" project "log" "--no-graph" "-r" "main"
                                       "-T" "commit_id"])))))
              workspace-listed?
              (fn []
                (str/includes?
                 (:out (require-success
                        "jj workspace list"
                        (run-process! ["jj" "--ignore-working-copy" "--no-pager"
                                       "-R" project "workspace" "list"])))
                 "agents/jj-stale"))]
          (spit (str (fs/path workspace-dir "first.txt")) "first change\n")
          (require-success "jj first commit"
                           (run-process! ["jj" "-R" workspace-dir "commit"
                                          "-m" "first change"]))
          (let [old-token
                (get-in (require-cli-success
                         "workspace-land-preview jj stale (before)"
                         (run-cli! "workspace-land-preview" "--project" project
                                   "--name" "jj-stale"))
                        [:json :preview :target_snapshot])
                before-commit-id (main-commit-id)]
            (is (seq old-token))
            (spit (str (fs/path workspace-dir "second.txt")) "second change\n")
            (require-success "jj second commit"
                             (run-process! ["jj" "-R" workspace-dir "commit"
                                            "-m" "second change"]))
            (let [{:keys [exit json]}
                  (run-cli! "workspace-land" "--project" project
                            "--name" "jj-stale"
                            "--expected-snapshot" old-token
                            "--finalize-quiesced")]
              (is (= 1 exit))
              (is (false? (:ok json)))
              (is (= "workspace-changed" (get-in json [:error :code])))
              (is (= before-commit-id (main-commit-id)))
              (is (workspace-listed?)))
            (let [{:keys [exit json]}
                  (require-cli-success
                   "workspace-land-preview jj stale (after)"
                   (run-cli! "workspace-land-preview" "--project" project
                             "--name" "jj-stale"))
                  preview (:preview json)
                  new-token (:target_snapshot preview)]
              (is (= 0 exit))
              (is (seq new-token))
              (is (not= old-token new-token))
              (is (= #{"first change" "second change"}
                     (set (mapv :subject (:commits preview)))))
              (let [{land-exit :exit land-json :json}
                    (require-cli-success
                     "workspace-land jj stale"
                     (run-cli! "workspace-land" "--project" project
                               "--name" "jj-stale"
                               "--expected-snapshot" new-token
                               "--finalize-quiesced"))]
                (is (= 0 land-exit))
                (is (true? (:ok land-json)))
                (is (false? (get-in land-json [:landed :workspace_retained])))
                (doseq [[file content] [["first.txt" "first change\n"]
                                        ["second.txt" "second change\n"]]]
                  (is (= content
                         (:out (require-success
                                (str "jj show landed " file)
                                (run-process!
                                 ["jj" "--ignore-working-copy" "--no-pager" "-R" project
                                  "file" "show" "-r" "main"
                                  (str "root:\"" file "\"")]))))))))))
        (finally
          (cleanup! root))))))

(deftest-with-manager git-stale-snapshot-land-refused-then-recovers-test
  (testing "workspace-land refuses a stale --expected-snapshot then succeeds with a fresh one (git)"
    (let [{:keys [root project]} (fresh-git-project!)]
      (try
        (let [{:keys [json]}
              (require-cli-success
               "workspace-add git stale-snapshot"
               (run-cli! "workspace-add" "--project" project
                         "--name" "git-stale"))
              workspace-dir (get-in json [:workspace :path])]
          (spit (str (fs/path workspace-dir "first.txt")) "first change\n")
          (require-success "git add first change" (run-git! workspace-dir "add" "-A"))
          (require-success "git first commit"
                           (run-git! workspace-dir "commit" "-q" "-m" "first change"))
          (let [old-token
                (get-in (require-cli-success
                         "workspace-land-preview git stale (before)"
                         (run-cli! "workspace-land-preview" "--project" project
                                   "--name" "git-stale"))
                        [:json :preview :target_snapshot])
                before-main (git-line! project "rev-parse" "main")]
            (is (seq old-token))
            (spit (str (fs/path workspace-dir "second.txt")) "second change\n")
            (require-success "git add second change" (run-git! workspace-dir "add" "-A"))
            (require-success "git second commit"
                             (run-git! workspace-dir "commit" "-q" "-m" "second change"))
            (let [{:keys [exit json]}
                  (run-cli! "workspace-land" "--project" project
                            "--name" "git-stale"
                            "--expected-snapshot" old-token
                            "--finalize-quiesced")]
              (is (= 1 exit))
              (is (false? (:ok json)))
              (is (= "workspace-changed" (get-in json [:error :code])))
              (is (= before-main (git-line! project "rev-parse" "main")))
              (is (str/includes?
                   (:out (require-success
                          "git worktree list after refused land"
                          (run-git! project "worktree" "list" "--porcelain")))
                   workspace-dir)))
            (let [{:keys [exit json]}
                  (require-cli-success
                   "workspace-land-preview git stale (after)"
                   (run-cli! "workspace-land-preview" "--project" project
                             "--name" "git-stale"))
                  preview (:preview json)
                  new-token (:target_snapshot preview)]
              (is (= 0 exit))
              (is (seq new-token))
              (is (not= old-token new-token))
              (is (= #{"first change" "second change"}
                     (set (mapv :subject (:commits preview)))))
              (let [{land-exit :exit land-json :json}
                    (require-cli-success
                     "workspace-land git stale"
                     (run-cli! "workspace-land" "--project" project
                               "--name" "git-stale"
                               "--expected-snapshot" new-token
                               "--finalize-quiesced"))]
                (is (= 0 land-exit))
                (is (true? (:ok land-json)))
                (is (false? (get-in land-json [:landed :workspace_retained])))
                (doseq [[file content] [["first.txt" "first change\n"]
                                        ["second.txt" "second change\n"]]]
                  (is (= content
                         (:out (require-success
                                (str "git show landed " file)
                                (run-git! project "show" (str "main:" file)))))))))))
        (finally
          (cleanup! root))))))

(let [{:keys [fail error] :as results} (run-tests 'test-agents-cli)
      skipped @skipped-integration-cases
      skipped-required? (and (integrations-required?) (seq skipped))]
  (println "SUMMARY:" (pr-str results))
  (println "SKIPPED INTEGRATION CASES:" (count skipped) (pr-str skipped))
  (System/exit (if (or (pos? fail) (pos? error) skipped-required?) 1 0)))
