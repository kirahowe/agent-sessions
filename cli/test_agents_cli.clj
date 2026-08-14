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
   {:root <root> :project <root>/project}. `root` being a fresh temp dir on
   every call is what gives each test its own isolated project -- and,
   since agents-cli's `workspaces/` convention now lives INSIDE the project
   (<project>/workspaces, not a directory shared by every project under a
   common parent), that isolation covers workspaces/ automatically too."
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

   Originally this existed because `jj workspace add` (no -r) forks the new
   workspace from the SAME PARENT(S) as the invoking workspace's own @, not
   from wherever a bookmark points -- so a `main` bookmark created over an
   undescribed root-commit snapshot (as fresh-jj-project! leaves default's
   own @) would point somewhere a plain workspace-add's fork never
   descended from.

   cmd-workspace-add now passes `-r <trunk>` itself whenever a trunk
   bookmark exists (see agents-cli's cmd-workspace-add), which sidesteps
   that forking behavior for every CLI-driven `run-cli \"workspace-add\"
   ...` call below -- but a properly committed `main` with real content is
   still needed for landing/diffing to have something concrete to compare
   against. And the OLD no-r forking behavior is still very much alive for
   any test that calls `jj workspace add` DIRECTLY rather than through the
   CLI: see workspace-land-shared-history-test, which deliberately uses
   that direct, hazardous form to reenact the incident this whole feature
   exists to prevent."
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

(defn direct-short-id
  "Ground truth: the 8-char short commit id jj itself would render for
   `revset` in `dir` -- the exact same commit_id.short(8) the CLI's own
   commit-brief-template uses for workspace-land-preview's :commits/
   :diverging/:conflicts and :bookmark_commit. Lets tests assert an EXACT
   :id string rather than merely a prefix-of-the-40-char-id match."
  [dir revset]
  (direct-jj-log dir revset "commit_id.short(8)"))

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
            (is (= (str project "/workspaces/testname") (:path ws)))
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
  (testing "dest path is exactly <project>/workspaces/<name>, dir created by the CLI"
    (let [{:keys [root project]} (fresh-jj-project!)
          workspaces-dir (str project "/workspaces")]
      (try
        (is (not (fs/exists? workspaces-dir))
            "workspaces/ must NOT exist before the call")
        (let [{:keys [json]} (run-cli "workspace-add" "--project" project "--name" "convname")]
          (is (= (str project "/workspaces/convname") (get-in json [:workspace :path])))
          (is (fs/exists? workspaces-dir)
              "workspaces/ parent dir should have been created by the CLI"))
        (finally (cleanup! root))))))

;; -----------------------------------------------------------------------
;; 3b. workspaces now nest INSIDE the project, and are invisible to it

(deftest workspace-nested-invisible-to-outer-test
  (testing "a workspace under <project>/workspaces/<name> is invisible to the outer (default) workspace's own jj status/file list, even with real content in it"
    (let [{:keys [root project]} (fresh-jj-project-on-main!)]
      (try
        (let [{:keys [json]} (run-cli "workspace-add" "--project" project "--name" "nested")
              ws-dir (get-in json [:workspace :path])]
          (is (str/starts-with? ws-dir (str project "/workspaces/"))
              "sanity: the workspace really is nested inside the project, not beside it")
          ;; Real, snapshotted content inside the nested workspace -- not
          ;; just an empty directory, which jj might trivially ignore for
          ;; unrelated reasons.
          (spit (str (fs/path ws-dir "nested-file.txt")) "NESTED_CONTENT\n")
          (is (zero? (:exit (sh "jj" "-R" ws-dir "st")))
              "sanity: snapshot the nested workspace's own real content")
          (let [outer-status (sh "jj" "--no-pager" "-R" project "st")
                outer-files (sh "jj" "--no-pager" "-R" project "file" "list")]
            (is (zero? (:exit outer-status)) "outer jj status must still succeed")
            (is (str/includes? (:out outer-status) "no changes")
                "the outer (default) workspace's own status must stay clean -- jj scopes working-copy tracking per-workspace, so a workspace nested under another workspace's root is never walked by the outer one")
            (is (not (str/includes? (:out outer-files) "nested-file.txt"))
                "the nested workspace's file must not appear in the outer workspace's own `jj file list`")))
        (finally (cleanup! root))))))

;; -----------------------------------------------------------------------
;; 4. dest-exists

(deftest workspace-add-dest-exists-test
  (testing "dest-exists error when the destination directory already exists"
    (let [{:keys [root project]} (fresh-jj-project!)
          dest (str project "/workspaces/blocked")]
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
  (testing "landing preserves a multi-commit chain plus a trailing uncommitted edit as distinct commits (merge model, not squash)"
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
            (is (= "THREE_CONTENT\n" (direct-jj-file-show project "main" "three.txt")))
            ;; THE MERGE-MODEL INVARIANT: the chain survives intact instead
            ;; of being squashed into one commit -- main is the described
            ;; trailing edit, main- is still c2, main-- is still c1.
            (is (str/includes? (direct-jj-log project "main" "description") "landed all three")
                "main should carry the --message description of the trailing edit")
            (is (str/includes? (direct-jj-log project "main-" "description") "c2")
                "main's parent should still be the c2 commit, with its own message intact")
            (is (str/includes? (direct-jj-log project "main--" "description") "c1")
                "main's grandparent should still be the c1 commit, with its own message intact")))
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
  (testing "missing --message -> bad-args, but ONLY when @ actually needs describing"
    (let [{:keys [root project]} (fresh-jj-project-on-main!)]
      (try
        (let [add (run-cli "workspace-add" "--project" project "--name" "foo")
              ws-dir (get-in add [:json :workspace :path])
              main-before (direct-jj-log project "main" commit-id-tpl)]
          (is (true? (get-in add [:json :ok])))
          ;; A non-empty, UNdescribed `@` is the one and only case where
          ;; --message is load-bearing: landing would otherwise have to
          ;; `jj describe -m ""` and push an empty description onto trunk.
          ;; This is exactly the condition workspace-land-preview reports
          ;; in advance as :needs_message.
          (spit (str (fs/path ws-dir "edit.txt")) "EDIT_CONTENT\n")
          (let [{:keys [exit json]} (run-cli "workspace-land" "--project" project "--name" "foo")]
            (is (= 1 exit))
            (is (false? (:ok json)))
            (is (= "bad-args" (get-in json [:error :code]))))
          (is (= main-before (direct-jj-log project "main" commit-id-tpl))
              "a refused land must leave trunk exactly where it was")
          (is (str/includes? (direct-jj-workspace-list project) "agents/foo")
              "a refused land must leave the workspace registered"))
        (finally (cleanup! root))))))

;; -----------------------------------------------------------------------
;; 18b. workspace-land: --message is OPTIONAL for the ordinary case
;;
;; This is the regression test for a real contract break: `require-flags!`
;; treats a blank value as a missing flag, so back when workspace-land
;; required :message, the app's normal "the session already committed its
;; work" land -- which has no message to send, because preview reported
;; :needs_message false -- failed outright with bad-args. Nothing caught it
;; because the app's own suite drives a fake engine, and the only real-CLI
;; round-trip covered create/delete rather than land.

(deftest workspace-land-no-message-ordinary-case-test
  (testing "a session that committed its own work lands with no --message at all"
    (let [{:keys [root project]} (fresh-jj-project-on-main!)]
      (try
        (let [add (run-cli "workspace-add" "--project" project "--name" "foo")
              ws-dir (get-in add [:json :workspace :path])
              main-before (direct-jj-log project "main" commit-id-tpl)]
          (is (true? (get-in add [:json :ok])))
          ;; Commit inside the workspace, leaving `@` empty and described
          ;; work behind it -- precisely what the app's sessions do.
          (spit (str (fs/path ws-dir "chore.txt")) "CHORE\n")
          (is (zero? (:exit (sh "jj" "-R" ws-dir "commit" "-m" "Do the chore")))
              "sanity: committing inside the workspace succeeded")
          (let [{:keys [exit json]} (run-cli "workspace-land" "--project" project "--name" "foo")]
            (is (= 0 exit) "no --message must NOT be treated as a missing required flag")
            (is (true? (:ok json)))
            (is (= (get-in json [:landed :commit_id]) (direct-jj-log project "main" commit-id-tpl))
                "trunk should point at the landed commit"))
          (is (= main-before (direct-jj-log project "main-" commit-id-tpl))
              "the landed commit descends directly from the old main")
          (is (str/includes? (direct-jj-log project "main" "description") "Do the chore")
              "the session's OWN commit message must survive -- --message never overwrites it")
          (is (= "CHORE\n" (direct-jj-file-show project "main" "chore.txt"))))
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
;; Phase 2 (merge-model landing). Shared background for the three tests
;; below: the incident this phase exists to prevent was plain `jj workspace
;; add` (no -r) forking a new workspace from the invoking workspace's own
;; @-parent -- i.e. the tip of the user's in-flight stack, not trunk -- and
;; a squash-based land then flattening whatever unlanded user commits
;; happened to sit in between. cmd-workspace-add now bases new workspaces
;; on trunk (23), and cmd-workspace-land refuses outright, before touching
;; anything, if a workspace's landing range shares history with any other
;; workspace's line anyway (24) -- two independent layers against the same
;; failure mode. 25 covers the merge model's other behavior change: land's
;; --message now only ever describes a trailing UNCOMMITTED edit, never a
;; chain commit the agent already described itself.

;; -----------------------------------------------------------------------
;; 23. workspace-add: bases the new workspace on trunk

(deftest workspace-add-bases-on-trunk-test
  (testing "workspace-add bases the new workspace on trunk, not on the default workspace's own unlanded stack"
    (let [{:keys [root project]} (fresh-jj-project-on-main!)]
      (try
        ;; Advance the DEFAULT workspace's own stack WITHOUT moving main --
        ;; exactly the shape of the incident: the user has unlanded work of
        ;; their own in flight when a new session workspace gets created.
        (is (zero? (:exit (sh "jj" "-R" project "commit" "-m" "unlanded user work")))
            "sanity: advance default's own stack without moving main")
        (let [main-id (direct-jj-log project "main" commit-id-tpl)
              add (run-cli "workspace-add" "--project" project "--name" "foo")]
          (is (true? (get-in add [:json :ok])))
          (let [ws-dir (get-in add [:json :workspace :path])]
            (is (= main-id (direct-jj-log ws-dir "@-" commit-id-tpl))
                "the new workspace's parent must be main -- NOT the unlanded commit sitting on top of it")))
        (finally (cleanup! root))))))

;; -----------------------------------------------------------------------
;; 24. workspace-land: shared-history guard (the incident reenactment)

(deftest workspace-land-shared-history-test
  (testing "landing refuses, with nothing mutated, when its chain shares history with another workspace's line"
    (let [{:keys [root project]} (fresh-jj-project-on-main!)
          ws-dir (str project "/workspaces/foo")]
      (try
        ;; main NOT moved -- this unlanded commit is what the workspace
        ;; below will hazardously fork on top of.
        (is (zero? (:exit (sh "jj" "-R" project "commit" "-m" "unlanded user work")))
            "sanity: advance default's own stack without moving main")
        ;; Create the workspace the OLD HAZARDOUS way: a direct `jj
        ;; workspace add` (bypassing the CLI, and its own trunk-basing)
        ;; forks from the invoking (default) workspace's own @-parent --
        ;; the unlanded commit above, not main. jj doesn't create
        ;; intermediate directories for `workspace add` (same as
        ;; cmd-workspace-add's own comment notes), so workspaces/ is made
        ;; by hand first.
        (fs/create-dirs (str project "/workspaces"))
        (is (zero? (:exit (sh "jj" "-R" project "workspace" "add" "--name" "agents/foo" ws-dir)))
            "sanity: direct workspace add (old hazardous form, no -r) succeeded")
        (spit (str (fs/path ws-dir "edit.txt")) "EDIT_CONTENT\n")
        (is (zero? (:exit (sh "jj" "-R" ws-dir "st")))
            "sanity: snapshot a real edit in the workspace")
        (let [ws-change-before (direct-jj-log ws-dir "@" change-id-tpl)
              main-before (direct-jj-log project "main" commit-id-tpl)
              {:keys [exit json]} (run-cli "workspace-land" "--project" project "--name" "foo"
                                            "--message" "should refuse")]
          (is (= 1 exit))
          (is (false? (:ok json)))
          (is (= "shared-history" (get-in json [:error :code])))
          (is (= main-before (direct-jj-log project "main" commit-id-tpl))
              "main must be unchanged -- the guard runs before any mutation")
          (is (str/includes? (direct-jj-workspace-list project) "agents/foo")
              "workspace must still be registered after refusal")
          (is (= ws-change-before (direct-jj-log ws-dir "@" change-id-tpl))
              "workspace's own @ change id must be unchanged after refusal"))
        (finally (cleanup! root))))))

;; -----------------------------------------------------------------------
;; 25. workspace-land: a trailing @ the agent already described keeps its
;;     own message, not --message

(deftest workspace-land-preserves-agent-own-description-test
  (testing "a described (but uncommitted) trailing @ keeps its own message -- --message is ignored for it"
    (let [{:keys [root project]} (fresh-jj-project-on-main!)]
      (try
        (let [add (run-cli "workspace-add" "--project" project "--name" "foo")
              ws-dir (get-in add [:json :workspace :path])]
          (is (true? (get-in add [:json :ok])))
          (spit (str (fs/path ws-dir "edit.txt")) "EDIT_CONTENT\n")
          (is (zero? (:exit (sh "jj" "-R" ws-dir "describe" "-m" "agent's own message")))
              "sanity: the agent described its own trailing @ before land")
          (let [{:keys [exit json]} (run-cli "workspace-land" "--project" project "--name" "foo"
                                              "--message" "should be ignored")]
            (is (= 0 exit))
            (is (true? (:ok json)))
            (is (str/includes? (direct-jj-log project "main" "description") "agent's own message")
                "main's description should be the agent's own, not --message")
            (is (not (str/includes? (direct-jj-log project "main" "description") "should be ignored"))
                "--message's value must not appear anywhere -- it was never used")
            (is (= "EDIT_CONTENT\n" (direct-jj-file-show project "main" "edit.txt"))
                "the described edit's content should still land at main")))
        (finally (cleanup! root))))))

;; -----------------------------------------------------------------------
;; Phase 3 (workspace-land-preview, rebase-onto-trunk). Shared background:
;; workspace-land-preview mirrors cmd-workspace-land step for step (both in
;; the implementation and, deliberately, in these tests -- the same setups
;; as the workspace-land tests above, just asserting on :preview instead of
;; :landed/an error). The one property land's own tests don't need to cover
;; is preview's central risk: every preview -- even one reporting no
;; conflicts -- performs a REAL rebase and rolls it back via `jj op
;; restore`, because jj has no dry-run rebase. 27 and 28 below exist
;; specifically to prove that rollback leaves the repo exactly as it found
;; it, in both the clean and the conflicting case.

;; -----------------------------------------------------------------------
;; 26. workspace-land-preview: commits list, oldest first, correct subjects,
;;     trailing empty @ excluded, needs_message false for it

(deftest workspace-land-preview-commits-list-test
  (testing "commits are listed oldest-first with correct ids/subjects, and an empty trailing @ is excluded"
    (let [{:keys [root project]} (fresh-jj-project-on-main!)]
      (try
        (let [add (run-cli "workspace-add" "--project" project "--name" "foo")
              ws-dir (get-in add [:json :workspace :path])]
          (is (true? (get-in add [:json :ok])))
          (spit (str (fs/path ws-dir "one.txt")) "ONE\n")
          (is (zero? (:exit (sh "jj" "-R" ws-dir "commit" "-m" "c1 commit"))))
          (spit (str (fs/path ws-dir "two.txt")) "TWO\n")
          (is (zero? (:exit (sh "jj" "-R" ws-dir "commit" "-m" "c2 commit")))
              "@ is now a fresh, empty, undescribed commit on top of c2")
          (let [c1-id (direct-short-id ws-dir "@--")
                c2-id (direct-short-id ws-dir "@-")
                {:keys [exit json]} (run-cli "workspace-land-preview" "--project" project "--name" "foo")]
            (is (= 0 exit))
            (is (true? (:ok json)))
            (let [preview (:preview json)]
              (is (= "main" (:bookmark preview)))
              (is (= (direct-short-id project "main") (:bookmark_commit preview)))
              (is (= [{:id c1-id :subject "c1 commit"}
                      {:id c2-id :subject "c2 commit"}]
                     (:commits preview))
                  "exactly c1 then c2, oldest first -- the trailing empty @ must not appear as a third entry")
              (is (= [] (:conflicts preview)))
              (is (false? (:needs_message preview))
                  "@ is empty, so land would never need --message for it regardless of description"))))
        (finally (cleanup! root))))))

;; -----------------------------------------------------------------------
;; 26b. workspace-land-preview: non-empty trailing @, undescribed vs described

(deftest workspace-land-preview-trailing-undescribed-test
  (testing "a non-empty, UNDESCRIBED trailing @ is included in :commits with a blank subject, and needs_message is true"
    (let [{:keys [root project]} (fresh-jj-project-on-main!)]
      (try
        (let [add (run-cli "workspace-add" "--project" project "--name" "foo")
              ws-dir (get-in add [:json :workspace :path])]
          (is (true? (get-in add [:json :ok])))
          (spit (str (fs/path ws-dir "trailing.txt")) "TRAILING\n")
          (is (zero? (:exit (sh "jj" "-R" ws-dir "st")))
              "sanity: snapshot the uncommitted, undescribed trailing edit")
          (let [trailing-id (direct-short-id ws-dir "@")
                {:keys [exit json]} (run-cli "workspace-land-preview" "--project" project "--name" "foo")]
            (is (= 0 exit))
            (let [preview (:preview json)]
              (is (= [{:id trailing-id :subject ""}] (:commits preview))
                  "the trailing @ IS included, with an empty subject (undescribed)")
              (is (true? (:needs_message preview))
                  "a non-empty, undescribed @ is exactly the case a real land would need --message for"))))
        (finally (cleanup! root))))))

(deftest workspace-land-preview-trailing-described-test
  (testing "a non-empty, DESCRIBED trailing @ is included with its own subject, and needs_message is false"
    (let [{:keys [root project]} (fresh-jj-project-on-main!)]
      (try
        (let [add (run-cli "workspace-add" "--project" project "--name" "foo")
              ws-dir (get-in add [:json :workspace :path])]
          (is (true? (get-in add [:json :ok])))
          (spit (str (fs/path ws-dir "trailing.txt")) "TRAILING\n")
          (is (zero? (:exit (sh "jj" "-R" ws-dir "describe" "-m" "my own trailing message")))
              "sanity: the agent described its own trailing @ before previewing")
          (let [trailing-id (direct-short-id ws-dir "@")
                {:keys [exit json]} (run-cli "workspace-land-preview" "--project" project "--name" "foo")]
            (is (= 0 exit))
            (let [preview (:preview json)]
              (is (= [{:id trailing-id :subject "my own trailing message"}] (:commits preview)))
              (is (false? (:needs_message preview))
                  "the trailing @ already has its own description -- a real land would never need --message for it"))))
        (finally (cleanup! root))))))

;; -----------------------------------------------------------------------
;; 27. workspace-land-preview: clean case rolls back perfectly

(deftest workspace-land-preview-clean-rolls-back-test
  (testing "a non-conflicting preview reports empty :conflicts and leaves the repo byte-identical"
    (let [{:keys [root project]} (fresh-jj-project-on-main!)]
      (try
        (let [add (run-cli "workspace-add" "--project" project "--name" "foo")
              ws-dir (get-in add [:json :workspace :path])]
          (is (true? (get-in add [:json :ok])))
          (spit (str (fs/path ws-dir "edit.txt")) "EDIT_CONTENT\n")
          (is (zero? (:exit (sh "jj" "-R" ws-dir "st"))))
          (let [main-before (direct-jj-log project "main" commit-id-tpl)
                ws-at-before (direct-jj-log ws-dir "@" change-id-tpl)
                {:keys [exit json]} (run-cli "workspace-land-preview" "--project" project "--name" "foo")]
            (is (= 0 exit))
            (is (true? (:ok json)))
            (is (= [] (get-in json [:preview :conflicts])))
            (is (= main-before (direct-jj-log project "main" commit-id-tpl))
                "THE ROLLBACK INVARIANT (clean case): main's commit id must be exactly what it was before the preview")
            (is (= ws-at-before (direct-jj-log ws-dir "@" change-id-tpl))
                "THE ROLLBACK INVARIANT (clean case): the workspace's own @ change id must be exactly what it was before the preview")
            (is (= "EDIT_CONTENT\n" (slurp (str (fs/path ws-dir "edit.txt"))))
                "the workspace's own uncommitted edit must be intact on disk after the preview's internal rebase-and-restore")
            (is (str/includes? (direct-jj-workspace-list project) "agents/foo")
                "the workspace must still be registered -- a preview never forgets it, unlike a real land")))
        (finally (cleanup! root))))))

;; -----------------------------------------------------------------------
;; 28. workspace-land-preview: conflicting case reports it AND rolls back

(deftest workspace-land-preview-conflict-rolls-back-test
  (testing "a genuinely conflicting chain is reported in :conflicts, and the repo is still left byte-identical"
    (let [{:keys [root project]} (fresh-jj-project-on-main!)]
      (try
        (let [add (run-cli "workspace-add" "--project" project "--name" "foo")
              ws-dir (get-in add [:json :workspace :path])
              seed-path (str (fs/path ws-dir "seed.txt"))]
          (is (true? (get-in add [:json :ok])))
          (spit seed-path "FOO_VERSION\n")
          (is (zero? (:exit (sh "jj" "-R" ws-dir "st"))))
          (let [ws-at-before (direct-jj-log ws-dir "@" change-id-tpl)]
            ;; Concurrently, via a DIRECT jj command against the DEFAULT
            ;; workspace, edit the SAME file with DIFFERENT content and move
            ;; main forward -- same recipe as workspace-land-conflict-test.
            (spit (str (fs/path project "seed.txt")) "MAIN_VERSION\n")
            (is (zero? (:exit (sh "jj" "-R" project "commit" "-m" "conflicting advance"))))
            (is (zero? (:exit (sh "jj" "-R" project "bookmark" "set" "main" "-r" "@-"))))
            (let [main-before (direct-jj-log project "main" commit-id-tpl)
                  {:keys [exit json]} (run-cli "workspace-land-preview" "--project" project "--name" "foo")
                  conflicts (get-in json [:preview :conflicts])]
              (is (= 0 exit) "a conflicting preview is still {\"ok\":true} -- it's a report, not a refusal")
              (is (true? (:ok json)))
              ;; NOTE on why this doesn't assert an exact :id: :conflicts is
              ;; read AFTER the preview's own internal rebase (step 10), so
              ;; its commit id is a freshly rebased one that never existed
              ;; before this call and no longer exists after the rollback --
              ;; there is no ground-truth id to pre-compute it against
              ;; without reimplementing the rebase ourselves. The subject
              ;; and count are what's actually observable and meaningful.
              (is (= 1 (count conflicts)))
              (is (= "" (:subject (first conflicts)))
                  "the conflicting commit is the workspace's own undescribed trailing @")
              (is (re-matches #"[0-9a-f]{8}" (:id (first conflicts)))
                  "id should still look like an 8-char short commit id")
              (is (= main-before (direct-jj-log project "main" commit-id-tpl))
                  "THE ROLLBACK INVARIANT (conflicting case): main's commit id must be exactly what it was before the preview")
              (is (= ws-at-before (direct-jj-log ws-dir "@" change-id-tpl))
                  "THE ROLLBACK INVARIANT (conflicting case): the workspace's own @ change id must be exactly what it was before the preview")
              (is (= "FOO_VERSION\n" (slurp seed-path))
                  "the workspace's own edit must be intact on disk, not left in a conflicted state, after the preview's rebase-and-restore")
              (is (str/includes? (direct-jj-workspace-list project) "agents/foo")
                  "the workspace must still be registered after a merely-reported conflict"))))
        (finally (cleanup! root))))))

;; -----------------------------------------------------------------------
;; 29. workspace-land-preview: throws the same codes, in the same
;;     situations, as workspace-land itself

(deftest workspace-land-preview-no-trunk-test
  (testing "no trunk bookmark -> no-trunk, nothing mutated"
    (let [{:keys [root project]} (fresh-jj-project!)]
      (try
        (let [add (run-cli "workspace-add" "--project" project "--name" "foo")]
          (is (true? (get-in add [:json :ok])))
          (let [{:keys [exit json]} (run-cli "workspace-land-preview" "--project" project "--name" "foo")]
            (is (= 1 exit))
            (is (false? (:ok json)))
            (is (= "no-trunk" (get-in json [:error :code])))
            (is (str/includes? (direct-jj-workspace-list project) "agents/foo")
                "nothing should have been mutated -- workspace still registered")))
        (finally (cleanup! root))))))

(deftest workspace-land-preview-nothing-to-land-test
  (testing "a fresh workspace with zero changes -> nothing-to-land"
    (let [{:keys [root project]} (fresh-jj-project-on-main!)]
      (try
        (let [add (run-cli "workspace-add" "--project" project "--name" "foo")]
          (is (true? (get-in add [:json :ok])))
          (let [{:keys [exit json]} (run-cli "workspace-land-preview" "--project" project "--name" "foo")]
            (is (= 1 exit))
            (is (false? (:ok json)))
            (is (= "nothing-to-land" (get-in json [:error :code])))
            (is (str/includes? (direct-jj-workspace-list project) "agents/foo")
                "workspace should still be registered")))
        (finally (cleanup! root))))))

(deftest workspace-land-preview-shared-history-test
  (testing "a chain sharing history with another workspace's line -> shared-history, nothing mutated"
    (let [{:keys [root project]} (fresh-jj-project-on-main!)
          ws-dir (str project "/workspaces/foo")]
      (try
        (is (zero? (:exit (sh "jj" "-R" project "commit" "-m" "unlanded user work")))
            "sanity: advance default's own stack without moving main")
        (fs/create-dirs (str project "/workspaces"))
        (is (zero? (:exit (sh "jj" "-R" project "workspace" "add" "--name" "agents/foo" ws-dir)))
            "sanity: direct workspace add (old hazardous form, no -r) succeeded")
        (spit (str (fs/path ws-dir "edit.txt")) "EDIT_CONTENT\n")
        (is (zero? (:exit (sh "jj" "-R" ws-dir "st"))))
        (let [ws-change-before (direct-jj-log ws-dir "@" change-id-tpl)
              main-before (direct-jj-log project "main" commit-id-tpl)
              {:keys [exit json]} (run-cli "workspace-land-preview" "--project" project "--name" "foo")]
          (is (= 1 exit))
          (is (false? (:ok json)))
          (is (= "shared-history" (get-in json [:error :code])))
          (is (= main-before (direct-jj-log project "main" commit-id-tpl))
              "main must be unchanged -- the guard runs before any mutation")
          (is (str/includes? (direct-jj-workspace-list project) "agents/foo")
              "workspace must still be registered after refusal")
          (is (= ws-change-before (direct-jj-log ws-dir "@" change-id-tpl))
              "workspace's own @ change id must be unchanged after refusal"))
        (finally (cleanup! root))))))

;; -----------------------------------------------------------------------
;; 30. workspace-land-preview: :diverging

(deftest workspace-land-preview-diverging-populated-test
  (testing "another workspace's real unlanded work shows up in :diverging"
    (let [{:keys [root project]} (fresh-jj-project-on-main!)]
      (try
        (let [foo (run-cli "workspace-add" "--project" project "--name" "foo")
              bar (run-cli "workspace-add" "--project" project "--name" "bar")
              foo-dir (get-in foo [:json :workspace :path])
              bar-dir (get-in bar [:json :workspace :path])]
          (is (true? (get-in foo [:json :ok])))
          (is (true? (get-in bar [:json :ok])))
          (spit (str (fs/path bar-dir "bar.txt")) "BAR_CONTENT\n")
          (is (zero? (:exit (sh "jj" "-R" bar-dir "commit" "-m" "bar work")))
              "bar has real, committed, still-unlanded work of its own")
          (spit (str (fs/path foo-dir "foo.txt")) "FOO_CONTENT\n")
          (is (zero? (:exit (sh "jj" "-R" foo-dir "st"))))
          (let [bar-work-id (direct-short-id bar-dir "@-")
                {:keys [exit json]} (run-cli "workspace-land-preview" "--project" project "--name" "foo")]
            (is (= 0 exit))
            (is (= [{:id bar-work-id :subject "bar work"}] (get-in json [:preview :diverging]))
                "bar's own unlanded commit shows up as diverging for foo's preview")))
        (finally (cleanup! root))))))

(deftest workspace-land-preview-diverging-empty-test
  (testing ":diverging is empty when no other workspace has real unlanded work"
    (let [{:keys [root project]} (fresh-jj-project-on-main!)]
      (try
        (let [add (run-cli "workspace-add" "--project" project "--name" "foo")
              ws-dir (get-in add [:json :workspace :path])]
          (is (true? (get-in add [:json :ok])))
          (spit (str (fs/path ws-dir "edit.txt")) "EDIT_CONTENT\n")
          (is (zero? (:exit (sh "jj" "-R" ws-dir "st"))))
          ;; default (the only OTHER registered workspace here) has never
          ;; been touched, so its own @ is empty -- ~empty() excludes it,
          ;; and there are no other agents/* sessions to contribute either.
          (let [{:keys [exit json]} (run-cli "workspace-land-preview" "--project" project "--name" "foo")]
            (is (= 0 exit))
            (is (= [] (get-in json [:preview :diverging])))))
        (finally (cleanup! root))))))

;; -----------------------------------------------------------------------
;; 31. rebase-onto-trunk: nothing to rebase

(deftest rebase-onto-trunk-nothing-to-rebase-test
  (testing "count 0, still {\"ok\":true}, when the default workspace has no fork over trunk"
    (let [{:keys [root project]} (fresh-jj-project-on-main!)]
      (try
        (let [{:keys [exit json]} (run-cli "rebase-onto-trunk" "--project" project)]
          (is (= 0 exit))
          (is (= {:ok true :rebased {:count 0 :bookmark "main"}} json)))
        (finally (cleanup! root))))))

;; -----------------------------------------------------------------------
;; 32. rebase-onto-trunk: rebases a real fork onto the moved trunk

(deftest rebase-onto-trunk-rebases-fork-test
  (testing "the default workspace's own unlanded commits are rebased onto trunk's new position, and the count is right"
    (let [{:keys [root project]} (fresh-jj-project-on-main!)]
      (try
        ;; The default workspace accumulates two commits of its own, ahead
        ;; of the ORIGINAL main -- the same "unlanded user work" shape the
        ;; shared-history tests above use, just here it's the thing under
        ;; test rather than a hazard to guard against.
        (spit (str (fs/path project "d1.txt")) "D1\n")
        (is (zero? (:exit (sh "jj" "-R" project "commit" "-m" "default work 1"))))
        (spit (str (fs/path project "d2.txt")) "D2\n")
        (is (zero? (:exit (sh "jj" "-R" project "commit" "-m" "default work 2"))))
        ;; Concurrently, land unrelated work through a session workspace so
        ;; main genuinely advances out from under default's fork.
        (let [add (run-cli "workspace-add" "--project" project "--name" "foo")
              ws-dir (get-in add [:json :workspace :path])]
          (is (true? (get-in add [:json :ok])))
          (spit (str (fs/path ws-dir "landed.txt")) "LANDED\n")
          (is (zero? (:exit (sh "jj" "-R" ws-dir "st"))))
          (let [{:keys [json]} (run-cli "workspace-land" "--project" project "--name" "foo" "--message" "landed")]
            (is (true? (:ok json)) "sanity: foo landed and advanced main")))
        (let [advanced-main-id (direct-jj-log project "main" commit-id-tpl)
              {:keys [exit json]} (run-cli "rebase-onto-trunk" "--project" project)]
          (is (= 0 exit))
          (is (= {:ok true :rebased {:count 2 :bookmark "main"}} json)
              "both of default's own commits were rebased")
          ;; `@---`, not `@--`: `jj commit` finalizes the working-copy commit
          ;; and leaves a FRESH EMPTY `@` on top, so after two commits the
          ;; chain is @ (empty) -> @- (work 2) -> @-- (work 1) -> @--- (main).
          ;; The rebase moves that whole subtree, empty tip included.
          (is (= advanced-main-id (direct-jj-log project "@---" commit-id-tpl))
              "default's rebased chain now sits on the ADVANCED main, not the original")
          (is (= "D1\n" (direct-jj-file-show project "@-" "d1.txt"))
              "default work 1's content survived the rebase")
          (is (= "D2\n" (direct-jj-file-show project "@" "d2.txt"))
              "default work 2's content survived the rebase")
          (is (= "LANDED\n" (direct-jj-file-show project "@" "landed.txt"))
              "the rebased chain also sees the landed content from main, as any rebase onto it would"))
        (finally (cleanup! root))))))

;; -----------------------------------------------------------------------
;; 33. rebase-onto-trunk: conflict -> rebase-conflict, nothing changed

(deftest rebase-onto-trunk-conflict-test
  (testing "a genuinely conflicting rebase reports rebase-conflict and leaves the repo unchanged"
    (let [{:keys [root project]} (fresh-jj-project-on-main!)]
      (try
        ;; default edits seed.txt without moving main.
        (spit (str (fs/path project "seed.txt")) "DEFAULT_VERSION\n")
        (is (zero? (:exit (sh "jj" "-R" project "commit" "-m" "default edits seed"))))
        ;; A session workspace edits the SAME file differently and lands,
        ;; advancing main to a version default's fork will conflict with.
        (let [add (run-cli "workspace-add" "--project" project "--name" "foo")
              ws-dir (get-in add [:json :workspace :path])]
          (is (true? (get-in add [:json :ok])))
          (spit (str (fs/path ws-dir "seed.txt")) "LANDED_VERSION\n")
          (is (zero? (:exit (sh "jj" "-R" ws-dir "st"))))
          (let [{:keys [json]} (run-cli "workspace-land" "--project" project "--name" "foo" "--message" "landed")]
            (is (true? (:ok json)) "sanity: foo landed and advanced main with a conflicting seed.txt")))
        (let [main-before (direct-jj-log project "main" commit-id-tpl)
              default-at-before (direct-jj-log project "@" change-id-tpl)
              {:keys [exit json]} (run-cli "rebase-onto-trunk" "--project" project)]
          (is (= 1 exit))
          (is (false? (:ok json)))
          (is (= "rebase-conflict" (get-in json [:error :code])))
          (is (= main-before (direct-jj-log project "main" commit-id-tpl))
              "main must be unchanged after the rolled-back rebase")
          (is (= default-at-before (direct-jj-log project "@" change-id-tpl))
              "default's own @ change id must be unchanged after the rolled-back rebase")
          (is (= "DEFAULT_VERSION\n" (slurp (str (fs/path project "seed.txt"))))
              "default's own edit must be intact on disk, not left in a conflicted state"))
        (finally (cleanup! root))))))

;; -----------------------------------------------------------------------
;; Runner: exit nonzero on any failure/error, for CI-style invocation.

(let [{:keys [fail error] :as results} (run-tests 'test-agents-cli)]
  (println "SUMMARY:" (pr-str results))
  (System/exit (if (or (pos? fail) (pos? error)) 1 0)))
