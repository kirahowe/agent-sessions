#!/usr/bin/env bb
;; Black-box behavioral tests for cli/agents-cli.
;;
;; Every test creates a REAL temp jj repo, invokes the agents-cli SCRIPT as a
;; subprocess (never calling its internals directly), parses its JSON stdout,
;; and asserts on both that JSON and on ground truth observed by running jj
;; directly. Temp dirs are always cleaned up, even on failure.
;;
;; Run with: bb cli/test_agents_cli.clj   (or the `cli-test` bb.edn task)

(ns test-agents-cli
  (:require [clojure.test :refer [deftest is testing run-tests]]
            [babashka.process :as p]
            [babashka.fs :as fs]
            [cheshire.core :as json]
            [clojure.string :as str]))

;; -----------------------------------------------------------------------
;; Plumbing

(def cli-path (str (fs/path (fs/parent (fs/absolutize *file*)) "agents-cli")))

;; bb's own absolute path, resolved once via this process's own (full) PATH
;; -- lets the stripped-PATH test below invoke bb explicitly, bypassing PATH
;; entirely for the subprocess it launches.
(def bb-path (str (fs/which "bb")))

(defn sh
  "Run a real subprocess, capturing stdout/stderr/exit separately."
  [& args]
  (let [{:keys [exit out err]} @(p/process args {:out :string :err :string})]
    {:exit exit :out out :err err}))

(defn run-cli
  "Invoke cli/agents-cli AS A SUBPROCESS with the given args, parse its
   stdout as JSON (keywordizing keys), and return exit/json/raw out+err.
   Also asserts the envelope contract: exactly one line on stdout."
  [& args]
  (let [{:keys [exit out err]} (apply sh cli-path args)
        trimmed (str/trim out)
        lines (remove str/blank? (str/split-lines out))]
    (is (= 1 (count lines))
        (str "stdout must be exactly one JSON line; got " (pr-str out)
             " (stderr: " (pr-str err) ")"))
    {:exit exit
     :json (json/parse-string trimmed true)
     :out out
     :err err}))

(defn cleanup! [root]
  (try (fs/delete-tree root) (catch Exception _ nil)))

(defn fresh-jj-project!
  "A unique temp root containing a real jj repo at <root>/project, seeded
   with one committed file so the repo has real content. Returns
   {:root <root> :project <root>/project}. `root` is also the directory the
   agents-cli `workspaces/` convention will use as the sibling parent, so
   each test gets its own isolated workspaces/ tree."
  []
  (let [root (str (fs/create-temp-dir))
        project (str (fs/path root "project"))
        init (sh "jj" "--quiet" "git" "init" project)]
    (when-not (zero? (:exit init))
      (throw (ex-info "test setup: jj git init failed" init)))
    (spit (str (fs/path project "seed.txt")) "seed\n")
    (let [snap (sh "jj" "-R" project "st")]
      (when-not (zero? (:exit snap))
        (throw (ex-info "test setup: jj st (snapshot) failed" snap))))
    {:root root :project project}))

(defn fresh-plain-dir!
  "A unique temp root containing an empty, non-repo directory at
   <root>/project."
  []
  (let [root (str (fs/create-temp-dir))
        project (str (fs/path root "project"))]
    (fs/create-dirs project)
    {:root root :project project}))

(defn fresh-git-only-dir!
  "A unique temp root containing a plain git (non-jj) repo at
   <root>/project."
  []
  (let [root (str (fs/create-temp-dir))
        project (str (fs/path root "project"))]
    (fs/create-dirs project)
    (let [init (sh "git" "init" "-q" project)]
      (when-not (zero? (:exit init))
        (throw (ex-info "test setup: git init failed" init))))
    {:root root :project project}))

(defn fresh-jj-project-on-main!
  "Like fresh-jj-project!, but the seed file is PROPERLY COMMITTED (via
   `jj commit -m \"seed\"`, not just `jj st`) and a `main` bookmark is
   created at that seed commit.

   This is required for workspace-land tests that add workspaces via the
   CLI (`run-cli \"workspace-add\" ...`): `jj workspace add` (no -r) forks
   the new workspace from the SAME PARENT(S) as the current workspace's @,
   not from wherever a bookmark points. If the default workspace's own @
   were still an undescribed snapshot sitting on the root commit (as in
   fresh-jj-project!), a workspace added from it would fork from the ROOT,
   completely empty, with `main` (if created at that snapshot) pointing
   somewhere the new workspace never descends from. Finalizing the seed via
   `jj commit` first -- which also advances the default workspace's own @ to
   a fresh empty commit on top -- and creating `main` at the now-finalized
   seed commit (@-) means workspace-add forks correctly from `main`."
  []
  (let [root (str (fs/create-temp-dir))
        project (str (fs/path root "project"))
        init (sh "jj" "--quiet" "git" "init" project)]
    (when-not (zero? (:exit init))
      (throw (ex-info "test setup: jj git init failed" init)))
    (spit (str (fs/path project "seed.txt")) "seed\n")
    (let [commit (sh "jj" "-R" project "commit" "-m" "seed")]
      (when-not (zero? (:exit commit))
        (throw (ex-info "test setup: jj commit (seed) failed" commit))))
    (let [bookmark (sh "jj" "-R" project "bookmark" "create" "main" "-r" "@-")]
      (when-not (zero? (:exit bookmark))
        (throw (ex-info "test setup: jj bookmark create main failed" bookmark))))
    {:root root :project project}))

(defn direct-jj-workspace-list
  "Ground truth: run `jj workspace list` directly (not through the CLI).

   --ignore-working-copy: several staleness tests below deliberately leave
   the DEFAULT workspace's own working copy stale on purpose (that's the
   scenario under test), and this ground-truth read -- a pure registry
   query, same as the CLI's own list-workspace-names -- must still succeed
   regardless. Safe for every other (non-stale) test too: the data this
   returns comes from the repo's View, not from live on-disk state, so the
   flag never changes what's reported."
  [project]
  (:out (sh "jj" "--ignore-working-copy" "--no-pager" "-R" project "workspace" "list")))

;; commit_id / change_id templates for the ground-truth log/id helpers below
;; -- same escaping idiom the CLI itself uses for -T arguments.
(def commit-id-tpl "commit_id ++ \"\\n\"")
(def change-id-tpl "change_id ++ \"\\n\"")

(defn direct-jj-log
  "Ground truth: `jj log --no-graph -r revset -T template`, run directly
   (never through the CLI) against `dir` via -R. `dir` may be a project
   root OR a specific workspace's own directory -- jj resolves -R to that
   directory's own workspace context (same as run-jj-in's cwd trick in the
   CLI itself), so revsets like \"@\" or \"default@\"/\"<jj-name>@\" resolve
   correctly either way. Trims trailing whitespace."
  [dir revset template]
  (str/trim (:out (sh "jj" "--no-pager" "-R" dir "log" "--no-graph" "-r" revset "-T" template))))

(defn direct-jj-file-show
  "Ground truth: raw contents of `path` at `revset`, via `jj file show`, run
   directly against `dir` via -R. `path` is wrapped in a `root:\"...\"`
   fileset pattern -- plain relative paths are resolved against CWD (not
   the repo root), which fails whenever `dir` isn't also the process's CWD
   (e.g. any -R call from outside the repo, as all of these are).

   --ignore-working-copy, for the same reason as direct-jj-workspace-list:
   this reads a NAMED revset (e.g. \"main\"), never `dir`'s own current `@`,
   so skipping the live snapshot of the possibly-stale current workspace is
   always safe and never changes the historical content returned."
  [dir revset path]
  (:out (sh "jj" "--ignore-working-copy" "--no-pager" "-R" dir "file" "show" "-r" revset (str "root:\"" path "\""))))

(defn direct-jj-bookmark-list
  "Ground truth: run `jj bookmark list` directly (not through the CLI)."
  [dir]
  (:out (sh "jj" "--no-pager" "-R" dir "bookmark" "list")))

;; -----------------------------------------------------------------------
;; 1. workspace-add with explicit --name

(deftest workspace-add-explicit-name-test
  (testing "workspace-add --name produces a correct ok envelope and real jj state"
    (let [{:keys [root project]} (fresh-jj-project!)]
      (try
        (let [{:keys [exit json]} (run-cli "workspace-add" "--project" project "--name" "testname")]
          (is (= 0 exit))
          (is (true? (:ok json)))
          (let [ws (:workspace json)]
            (is (= "testname" (:name ws)))
            (is (= "agents/testname" (:jj_name ws)))
            (is (= (str root "/workspaces/testname") (:path ws)))
            (is (= project (:project ws)))
            (is (fs/exists? (:path ws)) "dest dir should exist on disk")
            (is (str/includes? (direct-jj-workspace-list project) "agents/testname")
                "jj workspace list (run directly) should show the new workspace")))
        (finally (cleanup! root))))))

;; -----------------------------------------------------------------------
;; 2. workspace-add auto-name

(deftest workspace-add-auto-name-test
  (testing "workspace-add with no --name auto-generates adjective-noun and creates it"
    (let [{:keys [root project]} (fresh-jj-project!)]
      (try
        (let [{:keys [exit json]} (run-cli "workspace-add" "--project" project)]
          (is (= 0 exit))
          (is (true? (:ok json)))
          (let [name (get-in json [:workspace :name])]
            (is (re-matches #"^[a-z]+-[a-z]+$" name)
                (str "auto-generated name should be adjective-noun, got: " name))
            (is (str/includes? (direct-jj-workspace-list project) (str "agents/" name))
                "jj workspace list (run directly) should show the auto-named workspace")))
        (finally (cleanup! root))))))

;; -----------------------------------------------------------------------
;; 3. destination path convention

(deftest workspace-add-convention-path-test
  (testing "dest path is exactly <project-parent>/workspaces/<name>, dir created by the CLI"
    (let [{:keys [root project]} (fresh-jj-project!)
          workspaces-dir (str root "/workspaces")]
      (try
        (is (not (fs/exists? workspaces-dir))
            "workspaces/ must NOT exist before the call")
        (let [{:keys [json]} (run-cli "workspace-add" "--project" project "--name" "convname")]
          (is (= (str root "/workspaces/convname") (get-in json [:workspace :path])))
          (is (fs/exists? workspaces-dir)
              "workspaces/ parent dir should have been created by the CLI"))
        (finally (cleanup! root))))))

;; -----------------------------------------------------------------------
;; 4. dest-exists

(deftest workspace-add-dest-exists-test
  (testing "dest-exists error when the destination directory already exists"
    (let [{:keys [root project]} (fresh-jj-project!)
          dest (str root "/workspaces/blocked")]
      (try
        (fs/create-dirs dest)
        (let [{:keys [exit json]} (run-cli "workspace-add" "--project" project "--name" "blocked")]
          (is (= 1 exit))
          (is (false? (:ok json)))
          (is (= "dest-exists" (get-in json [:error :code])))
          (is (not (str/includes? (direct-jj-workspace-list project) "agents/blocked"))
              "no jj workspace should have been created as a side effect"))
        (finally (cleanup! root))))))

;; -----------------------------------------------------------------------
;; 5. name-conflict

(deftest workspace-add-name-conflict-test
  (testing "name-conflict error when the jj workspace name is already registered"
    (let [{:keys [root project]} (fresh-jj-project!)]
      (try
        (let [{:keys [json]} (run-cli "workspace-add" "--project" project "--name" "x")]
          (is (true? (:ok json)) "first add should succeed"))
        (let [{:keys [exit json]} (run-cli "workspace-add" "--project" project "--name" "x")]
          (is (= 1 exit))
          (is (false? (:ok json)))
          (is (= "name-conflict" (get-in json [:error :code]))))
        (finally (cleanup! root))))))

;; -----------------------------------------------------------------------
;; 6. not-a-jj-repo

(deftest not-a-jj-repo-test
  (testing "plain non-repo directory"
    (let [{:keys [root project]} (fresh-plain-dir!)]
      (try
        (let [{:keys [exit json]} (run-cli "workspace-add" "--project" project "--name" "x")]
          (is (= 1 exit))
          (is (false? (:ok json)))
          (is (= "not-a-jj-repo" (get-in json [:error :code]))))
        (finally (cleanup! root)))))
  (testing "git-only repo (no jj)"
    (let [{:keys [root project]} (fresh-git-only-dir!)]
      (try
        (let [{:keys [exit json]} (run-cli "workspace-add" "--project" project "--name" "x")]
          (is (= 1 exit))
          (is (false? (:ok json)))
          (is (= "not-a-jj-repo" (get-in json [:error :code]))))
        (finally (cleanup! root))))))

;; -----------------------------------------------------------------------
;; 7. workspace-forget

(deftest workspace-forget-test
  (testing "forget deregisters the jj workspace but never touches the directory"
    (let [{:keys [root project]} (fresh-jj-project!)]
      (try
        (let [{:keys [json]} (run-cli "workspace-add" "--project" project "--name" "forgetme")
              dest (get-in json [:workspace :path])]
          (is (fs/exists? dest) "sanity: dest dir exists right after add")
          (let [{:keys [exit json]} (run-cli "workspace-forget" "--project" project "--name" "forgetme")]
            (is (= 0 exit))
            (is (= {:ok true} json)))
          (is (not (str/includes? (direct-jj-workspace-list project) "agents/forgetme"))
              "jj workspace list should no longer show the forgotten workspace")
          (is (fs/exists? dest)
              "directory on disk must still exist after forget (forget is non-destructive)"))
        (finally (cleanup! root))))))

;; -----------------------------------------------------------------------
;; 8. workspace-list

(deftest workspace-list-test
  (testing "lists agents/ workspaces with correct dir_exists, excludes default"
    (let [{:keys [root project]} (fresh-jj-project!)]
      (try
        (let [alpha-path (get-in (run-cli "workspace-add" "--project" project "--name" "alpha")
                                  [:json :workspace :path])
              beta-path (get-in (run-cli "workspace-add" "--project" project "--name" "beta")
                                 [:json :workspace :path])]
          ;; simulate a workspace whose directory has gone missing on disk
          (fs/delete-tree beta-path)
          (let [{:keys [exit json]} (run-cli "workspace-list" "--project" project)
                entries (:workspaces json)
                by-name (into {} (map (juxt :name identity) entries))]
            (is (= 0 exit))
            (is (true? (:ok json)))
            (is (= 2 (count entries)) "both agents/ workspaces should be listed")
            (is (= alpha-path (get-in by-name ["alpha" :path])))
            (is (= "agents/alpha" (get-in by-name ["alpha" :jj_name])))
            (is (true? (get-in by-name ["alpha" :dir_exists])) "alpha's dir is intact")
            (is (= beta-path (get-in by-name ["beta" :path])))
            (is (false? (get-in by-name ["beta" :dir_exists])) "beta's dir was removed")
            (is (nil? (get by-name "default")) "the built-in default workspace must not appear")))
        (finally (cleanup! root))))))

;; -----------------------------------------------------------------------
;; 9. bad-args

(deftest bad-args-test
  (testing "unknown subcommand"
    (let [{:keys [exit json]} (run-cli "not-a-real-subcommand")]
      (is (= 1 exit))
      (is (false? (:ok json)))
      (is (= "bad-args" (get-in json [:error :code])))))
  (testing "missing required --project"
    (let [{:keys [exit json]} (run-cli "workspace-add" "--name" "x")]
      (is (= 1 exit))
      (is (false? (:ok json)))
      (is (= "bad-args" (get-in json [:error :code]))))))

;; -----------------------------------------------------------------------
;; 10. jj resolution: fallback candidates under a stripped PATH

(deftest workspace-add-jj-fallback-path-test
  (testing "with PATH stripped to /usr/bin:/bin (no jj on it), agents-cli still finds jj via its /opt/homebrew/bin or /usr/local/bin fallback candidates"
    (let [{:keys [root project]} (fresh-jj-project!)]
      (try
        (let [{:keys [exit out err]}
              @(p/process [bb-path cli-path "workspace-add" "--project" project "--name" "pathless"]
                          {:out :string :err :string :extra-env {"PATH" "/usr/bin:/bin"}})
              lines (remove str/blank? (str/split-lines out))]
          (is (= 1 (count lines))
              (str "stdout must be exactly one JSON line; got " (pr-str out)
                   " (stderr: " (pr-str err) ")"))
          (is (= 0 exit))
          (let [json (json/parse-string (str/trim out) true)]
            (is (true? (:ok json)))
            (is (str/includes? (direct-jj-workspace-list project) "agents/pathless")
                "jj workspace list (run directly) should show the new workspace")))
        (finally (cleanup! root))))))

;; -----------------------------------------------------------------------
;; 11. workspace-land: happy path, existing main

(deftest workspace-land-happy-path-main-test
  (testing "landing a single uncommitted edit onto an existing main bookmark"
    (let [{:keys [root project]} (fresh-jj-project-on-main!)]
      (try
        (let [add (run-cli "workspace-add" "--project" project "--name" "foo")
              ws-dir (get-in add [:json :workspace :path])
              default-before (direct-jj-log project "default@" change-id-tpl)
              main-before (direct-jj-log project "main" commit-id-tpl)]
          (is (true? (get-in add [:json :ok])) "sanity: workspace-add succeeded")
          ;; Establish ground truth of the uncommitted edit before landing,
          ;; by snapshotting it directly (mirrors how a real workspace
          ;; accumulates uncommitted edits).
          (spit (str (fs/path ws-dir "edit.txt")) "EDIT_CONTENT\n")
          (is (zero? (:exit (sh "jj" "-R" ws-dir "st")))
              "sanity: direct snapshot of the uncommitted edit succeeded")
          (let [{:keys [exit json]} (run-cli "workspace-land" "--project" project "--name" "foo"
                                              "--message" "landed msg")]
            (is (= 0 exit))
            (is (true? (:ok json)))
            (let [landed (:landed json)]
              (is (= "main" (:bookmark landed)))
              (is (= "foo" (:workspace landed)))
              (is (re-matches #"[0-9a-f]{40}" (:commit_id landed))
                  "commit_id should be a full 40-char hex commit id")
              (is (= (:commit_id landed) (direct-jj-log project "main" commit-id-tpl))
                  "envelope commit_id should match what main points at directly"))
            (is (= main-before (direct-jj-log project "main-" commit-id-tpl))
                "the landed commit should be descended directly from the OLD main")
            (is (str/includes? (direct-jj-log project "main" "description") "landed msg")
                "landed commit should carry the given message")
            (is (= "EDIT_CONTENT\n" (direct-jj-file-show project "main" "edit.txt"))
                "landed commit's tree should contain the edited file's content"))
          (is (not (str/includes? (direct-jj-workspace-list project) "agents/foo"))
              "jj workspace list (direct) should no longer show the forgotten workspace")
          (is (fs/exists? ws-dir) "the workspace directory should still exist on disk")
          (is (= default-before (direct-jj-log project "default@" change-id-tpl))
              "THE INVARIANT: default workspace's own @ change id must be untouched by landing"))
        (finally (cleanup! root))))))

;; -----------------------------------------------------------------------
;; 12. workspace-land: multi-commit chain plus trailing uncommitted edit

(deftest workspace-land-multi-commit-chain-test
  (testing "landing squashes a multi-commit chain plus a trailing uncommitted edit into one commit"
    (let [{:keys [root project]} (fresh-jj-project-on-main!)]
      (try
        (let [add (run-cli "workspace-add" "--project" project "--name" "foo")
              ws-dir (get-in add [:json :workspace :path])]
          (is (true? (get-in add [:json :ok])))
          (spit (str (fs/path ws-dir "one.txt")) "ONE_CONTENT\n")
          (is (zero? (:exit (sh "jj" "-R" ws-dir "commit" "-m" "c1"))))
          (spit (str (fs/path ws-dir "two.txt")) "TWO_CONTENT\n")
          (is (zero? (:exit (sh "jj" "-R" ws-dir "commit" "-m" "c2"))))
          (spit (str (fs/path ws-dir "three.txt")) "THREE_CONTENT\n")
          (is (zero? (:exit (sh "jj" "-R" ws-dir "st")))
              "sanity: snapshot the trailing uncommitted edit")
          (let [{:keys [exit json]} (run-cli "workspace-land" "--project" project "--name" "foo"
                                              "--message" "landed all three")]
            (is (= 0 exit))
            (is (true? (:ok json)))
            (is (= "ONE_CONTENT\n" (direct-jj-file-show project "main" "one.txt")))
            (is (= "TWO_CONTENT\n" (direct-jj-file-show project "main" "two.txt")))
            (is (= "THREE_CONTENT\n" (direct-jj-file-show project "main" "three.txt")))))
        (finally (cleanup! root))))))

;; -----------------------------------------------------------------------
;; 13. workspace-land: trunk advanced concurrently

(deftest workspace-land-concurrent-advance-test
  (testing "landing rebases onto a trunk that moved forward concurrently, keeping both sides' changes"
    (let [{:keys [root project]} (fresh-jj-project-on-main!)]
      (try
        (let [add (run-cli "workspace-add" "--project" project "--name" "foo")
              ws-dir (get-in add [:json :workspace :path])]
          (is (true? (get-in add [:json :ok])))
          (spit (str (fs/path ws-dir "foo-edit.txt")) "FOO_EDIT\n")
          (is (zero? (:exit (sh "jj" "-R" ws-dir "st"))))
          ;; Concurrently, via a DIRECT jj command against the DEFAULT
          ;; workspace (-R project, not the workspace dir), commit a
          ;; different file and move main forward.
          (spit (str (fs/path project "main-edit.txt")) "MAIN_EDIT\n")
          (is (zero? (:exit (sh "jj" "-R" project "commit" "-m" "advance main"))))
          (is (zero? (:exit (sh "jj" "-R" project "bookmark" "set" "main" "-r" "@-"))))
          (let [advanced-main-id (direct-jj-log project "main" commit-id-tpl)
                {:keys [exit json]} (run-cli "workspace-land" "--project" project "--name" "foo"
                                              "--message" "landed after advance")]
            (is (= 0 exit))
            (is (true? (:ok json)))
            (is (= advanced-main-id (direct-jj-log project "main-" commit-id-tpl))
                "the landed commit's parent should be the ADVANCED main, not the original")
            (is (= "FOO_EDIT\n" (direct-jj-file-show project "main" "foo-edit.txt"))
                "the workspace's own edit should be present at main")
            (is (= "MAIN_EDIT\n" (direct-jj-file-show project "main" "main-edit.txt"))
                "the concurrently-added main file should also be present at main")))
        (finally (cleanup! root))))))

;; -----------------------------------------------------------------------
;; 14. workspace-land: conflict rolls back cleanly

(deftest workspace-land-conflict-test
  (testing "a genuine content conflict rolls back cleanly and reports land-conflict"
    (let [{:keys [root project]} (fresh-jj-project-on-main!)]
      (try
        (let [add (run-cli "workspace-add" "--project" project "--name" "foo")
              ws-dir (get-in add [:json :workspace :path])
              seed-path (str (fs/path ws-dir "seed.txt"))]
          (is (true? (get-in add [:json :ok])))
          (spit seed-path "FOO_VERSION\n")
          (is (zero? (:exit (sh "jj" "-R" ws-dir "st"))))
          (let [ws-change-before (direct-jj-log ws-dir "@" change-id-tpl)]
            ;; Concurrently, via a DIRECT jj command against the DEFAULT
            ;; workspace, edit the SAME file with DIFFERENT content and move
            ;; main forward -- landing will now produce a real conflict.
            (spit (str (fs/path project "seed.txt")) "MAIN_VERSION\n")
            (is (zero? (:exit (sh "jj" "-R" project "commit" "-m" "conflicting advance"))))
            (is (zero? (:exit (sh "jj" "-R" project "bookmark" "set" "main" "-r" "@-"))))
            (let [main-before (direct-jj-log project "main" commit-id-tpl)
                  {:keys [exit json]} (run-cli "workspace-land" "--project" project "--name" "foo"
                                                "--message" "should conflict")]
              (is (= 1 exit))
              (is (false? (:ok json)))
              (is (= "land-conflict" (get-in json [:error :code])))
              (is (= main-before (direct-jj-log project "main" commit-id-tpl))
                  "main bookmark must be unchanged (still at its advanced position) after rollback")
              (is (str/includes? (direct-jj-workspace-list project) "agents/foo")
                  "workspace must still be registered after rollback")
              (is (= "FOO_VERSION\n" (slurp seed-path))
                  "workspace's own edit must be intact on disk after rollback")
              (is (= ws-change-before (direct-jj-log ws-dir "@" change-id-tpl))
                  "workspace's own @ (its commit chain/working-copy edit) must be exactly restored after rollback")
              (is (fs/exists? ws-dir) "workspace directory must still exist on disk"))))
        (finally (cleanup! root))))))

;; -----------------------------------------------------------------------
;; 15. workspace-land: no trunk, no --create-trunk

(deftest workspace-land-no-trunk-test
  (testing "no bookmarks at all and no --create-trunk -> no-trunk, nothing mutated"
    (let [{:keys [root project]} (fresh-jj-project!)]
      (try
        (let [add (run-cli "workspace-add" "--project" project "--name" "foo")]
          (is (true? (get-in add [:json :ok])))
          (let [{:keys [exit json]} (run-cli "workspace-land" "--project" project "--name" "foo"
                                              "--message" "x")]
            (is (= 1 exit))
            (is (false? (:ok json)))
            (is (= "no-trunk" (get-in json [:error :code])))
            (is (str/includes? (direct-jj-workspace-list project) "agents/foo")
                "nothing should have been mutated -- workspace still registered")))
        (finally (cleanup! root))))))

;; -----------------------------------------------------------------------
;; 16. workspace-land: no trunk, --create-trunk main

(deftest workspace-land-create-trunk-test
  (testing "no existing trunk, --create-trunk creates one at the landed commit"
    (let [{:keys [root project]} (fresh-jj-project!)]
      (try
        (let [add (run-cli "workspace-add" "--project" project "--name" "foo")
              ws-dir (get-in add [:json :workspace :path])]
          (is (true? (get-in add [:json :ok])))
          ;; Concurrently, via a DIRECT jj command against the DEFAULT
          ;; workspace, advance default's own @ with a commit that is
          ;; completely unrelated to `foo` (which already forked off before
          ;; this happens). Since there's no existing trunk bookmark to
          ;; rebase onto, --create-trunk must compute its base via
          ;; heads(::@ & ::default@) -- this commit must NOT leak in as a
          ;; required ancestor of the newly-created bookmark.
          (spit (str (fs/path project "default-only.txt")) "DEFAULT_ONLY\n")
          (is (zero? (:exit (sh "jj" "-R" project "commit" "-m" "default advances independently"))))
          (let [default-only-change-id (direct-jj-log project "@-" change-id-tpl)
                default-before (direct-jj-log project "default@" change-id-tpl)]
            (spit (str (fs/path ws-dir "new-file.txt")) "NEW_CONTENT\n")
            (is (zero? (:exit (sh "jj" "-R" ws-dir "st")))
                "sanity: something to land, else this would hit nothing-to-land instead")
            (let [{:keys [exit json]} (run-cli "workspace-land" "--project" project "--name" "foo"
                                                "--message" "created trunk"
                                                "--create-trunk" "main")]
              (is (= 0 exit))
              (is (true? (:ok json)))
              (is (= "main" (get-in json [:landed :bookmark])))
              (is (str/includes? (direct-jj-bookmark-list project) "main")
                  "main bookmark should now exist")
              (is (= (get-in json [:landed :commit_id]) (direct-jj-log project "main" commit-id-tpl))
                  "main should point at the landed commit")
              (is (str/blank? (direct-jj-log project (str "::main & " default-only-change-id) change-id-tpl))
                  "default workspace's own independent commit must NOT be an ancestor of the newly-created main bookmark"))
            (is (= default-before (direct-jj-log project "default@" change-id-tpl))
                "THE INVARIANT: default workspace's own @ change id must be untouched by landing")))
        (finally (cleanup! root))))))

;; -----------------------------------------------------------------------
;; 17. workspace-land: fresh workspace, zero changes

(deftest workspace-land-nothing-to-land-test
  (testing "a fresh workspace with zero changes -> nothing-to-land"
    (let [{:keys [root project]} (fresh-jj-project-on-main!)]
      (try
        (let [add (run-cli "workspace-add" "--project" project "--name" "foo")]
          (is (true? (get-in add [:json :ok])))
          (let [{:keys [exit json]} (run-cli "workspace-land" "--project" project "--name" "foo"
                                              "--message" "x")]
            (is (= 1 exit))
            (is (false? (:ok json)))
            (is (= "nothing-to-land" (get-in json [:error :code])))
            (is (str/includes? (direct-jj-workspace-list project) "agents/foo")
                "workspace should still be registered")))
        (finally (cleanup! root))))))

;; -----------------------------------------------------------------------
;; 18. workspace-land: missing --message

(deftest workspace-land-missing-message-test
  (testing "missing --message -> bad-args"
    (let [{:keys [root project]} (fresh-jj-project-on-main!)]
      (try
        (let [add (run-cli "workspace-add" "--project" project "--name" "foo")]
          (is (true? (get-in add [:json :ok])))
          (let [{:keys [exit json]} (run-cli "workspace-land" "--project" project "--name" "foo")]
            (is (= 1 exit))
            (is (false? (:ok json)))
            (is (= "bad-args" (get-in json [:error :code])))))
        (finally (cleanup! root))))))

;; -----------------------------------------------------------------------
;; 19. workspace-land: unregistered workspace name

(deftest workspace-land-unregistered-workspace-test
  (testing "--name referring to a never-added workspace -> jj-failed"
    (let [{:keys [root project]} (fresh-jj-project-on-main!)]
      (try
        (let [{:keys [exit json]} (run-cli "workspace-land" "--project" project "--name" "does-not-exist"
                                            "--message" "x")]
          (is (= 1 exit))
          (is (false? (:ok json)))
          (is (= "jj-failed" (get-in json [:error :code]))))
        (finally (cleanup! root))))))

;; -----------------------------------------------------------------------
;; Staleness hardening (Phase 1). Shared background for all three tests
;; below: jj auto-heals a workspace's OWN checkout being abandoned when
;; that checkout is trivial (empty, no description) -- it silently
;; replaces it with a fresh empty commit in the SAME operation, and the
;; workspace never goes stale at all. Genuine staleness (an actual
;; `The working copy is stale` error, requiring `jj workspace update-stale`
;; to recover) only happens when the abandoned checkout had real content
;; that diverged from its parent at the moment it was abandoned. Verified
;; directly against this machine's jj 0.43.0 by reproducing both outcomes
;; before writing these tests -- see this file's companion report for
;; specifics. So every scenario below deliberately gives the
;; soon-to-be-abandoned `@` some real (snapshotted) content first, even
;; where that content is otherwise irrelevant to the test, purely to
;; trigger genuine staleness rather than silent self-healing.

;; -----------------------------------------------------------------------
;; 20. workspace-forget: default workspace's own working copy is stale

(deftest workspace-forget-stale-default-test
  (testing "forget succeeds even when the DEFAULT workspace's own working copy is stale"
    (let [{:keys [root project]} (fresh-jj-project-on-main!)]
      (try
        (let [add (run-cli "workspace-add" "--project" project "--name" "foo")
              ws-dir (get-in add [:json :workspace :path])]
          (is (true? (get-in add [:json :ok])) "sanity: workspace-add succeeded")
          ;; Give default's own @ real content (see the staleness-hardening
          ;; note above for why), then abandon it from a DIFFERENT
          ;; workspace's context (foo's) -- this is the same shape of
          ;; mistake the incident hit: some jj activity elsewhere rewrites
          ;; the default workspace's own checkout out from under it.
          (spit (str (fs/path project "default-edit.txt")) "DEFAULT_EDIT\n")
          (is (zero? (:exit (sh "jj" "-R" project "st")))
              "sanity: snapshot default's own real edit")
          (let [default-id (direct-jj-log ws-dir "default@" commit-id-tpl)]
            (is (zero? (:exit (sh "jj" "-R" ws-dir "abandon" default-id)))
                "sanity: direct abandon of default's @ (from foo's context) succeeded"))
          (let [{:keys [exit err]} (sh "jj" "--no-pager" "-R" project "st")]
            (is (not (zero? exit)) "sanity precondition: default workspace should now be stale")
            (is (str/includes? err "stale") "sanity precondition: jj st should mention staleness"))
          (let [{:keys [exit json]} (run-cli "workspace-forget" "--project" project "--name" "foo")]
            (is (= 0 exit))
            (is (= {:ok true} json)))
          (is (not (str/includes? (direct-jj-workspace-list project) "agents/foo"))
              "jj workspace list (direct) should no longer show the forgotten workspace"))
        (finally (cleanup! root))))))

;; -----------------------------------------------------------------------
;; 21. workspace-land: default workspace's own working copy is stale
;;     (the incident scenario -- a completed land must not report failure)

(deftest workspace-land-stale-default-test
  (testing "landing succeeds end-to-end even when the DEFAULT workspace's own working copy is stale"
    (let [{:keys [root project]} (fresh-jj-project-on-main!)]
      (try
        (let [add (run-cli "workspace-add" "--project" project "--name" "foo")
              ws-dir (get-in add [:json :workspace :path])]
          (is (true? (get-in add [:json :ok])) "sanity: workspace-add succeeded")
          ;; A real edit in the SESSION workspace -- this is the content
          ;; that must actually reach main below.
          (spit (str (fs/path ws-dir "edit.txt")) "STALE_LAND_CONTENT\n")
          (is (zero? (:exit (sh "jj" "-R" ws-dir "st")))
              "sanity: snapshot the workspace's own edit")
          ;; Make DEFAULT genuinely stale -- same recipe and reasoning as
          ;; workspace-forget-stale-default-test above.
          (spit (str (fs/path project "default-edit.txt")) "DEFAULT_EDIT\n")
          (is (zero? (:exit (sh "jj" "-R" project "st")))
              "sanity: snapshot default's own real edit")
          (let [default-id (direct-jj-log ws-dir "default@" commit-id-tpl)]
            (is (zero? (:exit (sh "jj" "-R" ws-dir "abandon" default-id)))
                "sanity: direct abandon of default's @ succeeded"))
          (let [{:keys [exit err]} (sh "jj" "--no-pager" "-R" project "st")]
            (is (not (zero? exit)) "sanity precondition: default workspace should now be stale")
            (is (str/includes? err "stale") "sanity precondition: jj st should mention staleness"))
          (let [{:keys [exit json]} (run-cli "workspace-land" "--project" project "--name" "foo"
                                              "--message" "landed despite stale default")]
            (is (= 0 exit)
                "THE INCIDENT: a land that actually succeeded must not be reported as a failure")
            (is (true? (:ok json)))
            (is (nil? (:warning json))
                "no :warning expected -- --ignore-working-copy on the final forget makes it succeed regardless of default's staleness")
            (is (= "STALE_LAND_CONTENT\n" (direct-jj-file-show project "main" "edit.txt"))
                "the landed content must be present at main"))
          (is (not (str/includes? (direct-jj-workspace-list project) "agents/foo"))
              "workspace should be deregistered like any other successful land"))
        (finally (cleanup! root))))))

;; -----------------------------------------------------------------------
;; 22. workspace-land: the SESSION workspace's own working copy is stale,
;;     and the step-0.5 update-stale preflight recovers it

(deftest workspace-land-stale-workspace-recovers-test
  (testing "landing recovers a stale SESSION workspace via the update-stale preflight"
    (let [{:keys [root project]} (fresh-jj-project-on-main!)]
      (try
        (let [add (run-cli "workspace-add" "--project" project "--name" "foo")
              ws-dir (get-in add [:json :workspace :path])]
          (is (true? (get-in add [:json :ok])) "sanity: workspace-add succeeded")
          ;; c1's content goes safely into a chain commit; @ becomes a
          ;; fresh commit on top of it.
          (spit (str (fs/path ws-dir "one.txt")) "C1_CONTENT\n")
          (is (zero? (:exit (sh "jj" "-R" ws-dir "commit" "-m" "c1")))
              "sanity: c1 committed, leaving a fresh @ on top")
          ;; That fresh @ is trivial (empty, undescribed) -- give it real
          ;; content first so abandoning it below produces genuine
          ;; staleness rather than silent self-healing (see the
          ;; staleness-hardening note above). This throwaway content is
          ;; expected to be LOST by the update-stale recovery -- only c1's
          ;; already-committed content is asserted on below.
          (spit (str (fs/path ws-dir "throwaway.txt")) "THROWAWAY\n")
          (let [ws-head-id (direct-jj-log ws-dir "@" commit-id-tpl)]
            (is (zero? (:exit (sh "jj" "-R" project "abandon" ws-head-id)))
                "sanity: direct abandon of the workspace's own @, from the PROJECT side, succeeded"))
          (let [{:keys [exit err]} (sh "jj" "--no-pager" "-R" ws-dir "st")]
            (is (not (zero? exit)) "sanity precondition: the workspace should now be stale")
            (is (str/includes? err "stale") "sanity precondition: jj st should mention staleness"))
          (let [{:keys [exit json]} (run-cli "workspace-land" "--project" project "--name" "foo"
                                              "--message" "landed after workspace recovery")]
            (is (= 0 exit))
            (is (true? (:ok json)))
            (is (= "C1_CONTENT\n" (direct-jj-file-show project "main" "one.txt"))
                "c1's content must be present at main despite the workspace having been stale")))
        (finally (cleanup! root))))))

;; -----------------------------------------------------------------------
;; Runner: exit nonzero on any failure/error, for CI-style invocation.

(let [{:keys [fail error] :as results} (run-tests 'test-agents-cli)]
  (println "SUMMARY:" (pr-str results))
  (System/exit (if (or (pos? fail) (pos? error)) 1 0)))
