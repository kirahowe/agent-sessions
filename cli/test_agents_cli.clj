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

(defn direct-jj-workspace-list
  "Ground truth: run `jj workspace list` directly (not through the CLI)."
  [project]
  (:out (sh "jj" "--no-pager" "-R" project "workspace" "list")))

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
;; Runner: exit nonzero on any failure/error, for CI-style invocation.

(let [{:keys [fail error] :as results} (run-tests 'test-agents-cli)]
  (println "SUMMARY:" (pr-str results))
  (System/exit (if (or (pos? fail) (pos? error)) 1 0)))
