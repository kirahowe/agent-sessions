#!/usr/bin/env bb

(ns test-agents-cli
  (:require [babashka.fs :as fs]
            [babashka.process :as p]
            [cheshire.core :as json]
            [clojure.string :as str]
            [clojure.test :refer [deftest is run-tests testing]]))

(def ^:private cli-dir (fs/parent (fs/absolutize *file*)))
(def ^:private cli-path (str (fs/path cli-dir "agents-cli")))
(def ^:private manager-root
  (fs/path (System/getProperty "user.home") "code" "projects"
           "workstream-manager"))
(def ^:private manager-entrypoint
  (fs/path manager-root "src" "wsm" "cli.clj"))

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
  (apply run-cli-at-with-manager! script manager-root args))

(defn- run-cli! [& args]
  (apply run-cli-at! cli-path args))

(defn- manager-checkout-available? []
  (fs/regular-file? manager-entrypoint))

(defmacro deftest-with-manager [name & body]
  `(deftest ~name
     (if (manager-checkout-available?)
       (do ~@body)
       (is true "Skipped: local workstream-manager checkout is unavailable"))))

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
    (if (manager-checkout-available?)
      (let [root (fs/create-temp-dir)]
        (try
          (let [packaged-cli (str (fs/path root "agents-cli"))]
            (fs/copy cli-path packaged-cli)
            (.setExecutable (java.io.File. packaged-cli) true)
            (doseq [[label script] [["repository" cli-path]
                                    ["copied script" packaged-cli]]]
              (testing label
                (let [{:keys [exit json]}
                      (run-cli-at-with-manager! script manager-root
                                                "not-a-command")]
                  (is (= 1 exit))
                  (is (false? (:ok json)))
                  (is (= "bad-args" (get-in json [:error :code])))
                  (is (string? (get-in json [:error :message])))))))
          (finally
            (cleanup! root))))
      (is true "Skipped: local workstream-manager checkout is unavailable")))
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
                preview (:preview preview-json)]
            (is (= 0 preview-exit))
            (is (= "jj" (:vcs preview)))
            (is (= ["jj consumer change"] (mapv :subject (:commits preview))))
            (is (= [] (:conflicts preview)))
            (is (false? (:needs_message preview))))
          (let [{land-exit :exit land-json :json}
                (require-cli-success
                 "workspace-land jj consumer"
                 (run-cli! "workspace-land" "--project" project
                           "--name" "jj-consumer"))
                show-result
                (run-process!
                 ["jj" "--ignore-working-copy" "--no-pager" "-R" project
                  "file" "show" "-r" "main" "root:\"consumer.txt\""])
                shown (:out (require-success "jj show landed file" show-result))]
            (is (= 0 land-exit))
            (is (true? (:ok land-json)))
            (is (= "jj consumer\n" shown))))
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
                preview (:preview preview-json)]
            (is (= 0 preview-exit))
            (is (= "git" (:vcs preview)))
            (is (= ["git consumer change"] (mapv :subject (:commits preview))))
            (is (= [] (:conflicts preview)))
            (is (false? (:needs_message preview))))
          (let [{land-exit :exit land-json :json}
                (require-cli-success
                 "workspace-land git consumer"
                 (run-cli! "workspace-land" "--project" project
                           "--name" "git-consumer"))]
            (is (= 0 land-exit))
            (is (true? (:ok land-json)))
            (is (= (get-in land-json [:landed :commit_id])
                   (git-line! project "rev-parse" "main")))
            (is (= "git consumer\n"
                   (:out (require-success
                          "git show landed file"
                          (run-git! project "show" "main:consumer.txt")))))))
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


(let [{:keys [fail error] :as results} (run-tests 'test-agents-cli)]
  (println "SUMMARY:" (pr-str results))
  (System/exit (if (or (pos? fail) (pos? error)) 1 0)))
