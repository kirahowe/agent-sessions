#!/usr/bin/env bb
;; Publish GitHub `main` as the rolling nightly release — the build the
;; in-app updater serves. Run as `bb publish`; see README "Releases".
;;
;; Nothing is built here. The Nightly workflow on GitHub builds the app,
;; signs the Sparkle appcast with a key that exists only in the repository
;; secrets, and recreates the `nightly` release. This script is the hand
;; sequence that replaced — `gh workflow run`, find the run, `gh run watch`,
;; look at the release — with two guards in front of it: refuse when the
;; local `main` bookmark is not what GitHub has, since an unpushed fix would
;; otherwise be silently left out of "the latest"; and do nothing when the
;; current nightly already is `main`, which the workflow would also decide,
;; but only after spinning up a runner.
(ns publish
  (:require [babashka.process :as p]
            [cheshire.core :as json]
            [clojure.string :as str]))

;; The repository is spelled out rather than inferred from the checkout so
;; this also works from a jj workspace, which has no .git for gh to read.
;; nightly.yml and project.yml (SUFeedURL) hardcode the same name.
(def repo "kirahowe/agent-sessions")
(def branch "main")
(def workflow "nightly.yml")
(def tag "nightly")

(defn- short-id [sha] (subs sha 0 8))

(defn- fail [& msg]
  (binding [*out* *err*] (println (apply str msg)))
  (System/exit 1))

(defn- gh
  "Run gh against the release repository; returns {:exit :out :err}."
  [& args]
  (-> (apply p/sh {:extra-env {"GH_REPO" repo}} "gh" args)
      (update :out str/trim)))

(defn- gh!
  "Like `gh`, but returns stdout and fails the script on a non-zero exit."
  [& args]
  (let [{:keys [exit out err]} (apply gh args)]
    (when-not (zero? exit)
      (fail "gh " (str/join " " args) " failed:\n" err))
    out))

(defn- gh-json [& args]
  (json/parse-string (apply gh! args) true))

(defn- local-main
  "[commit-id subject] of the local `main` bookmark. jj is asked first:
  in this colocated repo its view is the authoritative one, and the git
  ref is only re-exported when a jj command runs. A plain git clone falls
  back to the branch."
  []
  (let [jj (p/sh "jj" "--ignore-working-copy" "--no-pager" "log" "-r" branch
                 "--no-graph" "-T" "commit_id ++ \" \" ++ description.first_line()")
        r  (if (zero? (:exit jj)) jj (p/sh "git" "log" "-1" "--format=%H %s" branch))]
    (when-not (zero? (:exit r))
      (fail "Cannot read the local " branch " bookmark:\n" (:err r)))
    (str/split (str/trim (:out r)) #" " 2)))

(defn- github-main []
  (gh! "api" (str "repos/{owner}/{repo}/git/ref/heads/" branch) "--jq" ".object.sha"))

(defn- release
  "The rolling release as it stands: its name, URL, publication time, and
  the commit it was built from (the `nightly` tag, which is also what the
  workflow's own skip-if-unchanged guard compares against). nil before the
  first release ever."
  []
  (let [{:keys [exit out]} (gh "release" "view" tag "--json" "name,url,publishedAt")]
    (when (zero? exit)
      (-> (json/parse-string out true)
          (assoc :built (gh! "api" (str "repos/{owner}/{repo}/git/ref/tags/" tag)
                             "--jq" ".object.sha"))))))

(defn- dispatch-runs
  "{run-id url} for recent manual runs of the workflow."
  []
  (->> (gh-json "run" "list" "--workflow" workflow "--event" "workflow_dispatch"
                "--branch" branch "--json" "databaseId,url" "--limit" "10")
       (map (juxt :databaseId :url))
       (into {})))

(defn- dispatch!
  "Start the workflow on `branch` and return the run it started as
  {:id :url}. gh hands back no reference to the run it just triggered, so
  it is found by difference — the newest manual run that was not listed
  beforehand — and polled for, since GitHub takes a few seconds to create
  it."
  []
  (let [before (set (keys (dispatch-runs)))]
    (gh! "workflow" "run" workflow "--ref" branch)
    (loop [attempts 30]
      (let [new (apply dissoc (dispatch-runs) before)]
        (cond
          (seq new)        (let [id (apply max (keys new))] {:id id :url (get new id)})
          (zero? attempts) (fail "Dispatched " workflow " but no run appeared within a minute: "
                                 "https://github.com/" repo "/actions")
          :else            (do (Thread/sleep 2000) (recur (dec attempts))))))))

(defn- watch! [{:keys [id url]}]
  (println "Watching run" id "—" url)
  (let [{:keys [exit]} (p/shell {:continue true :extra-env {"GH_REPO" repo}}
                                "gh" "run" "watch" (str id) "--exit-status")]
    (when-not (zero? exit)
      (fail "The run did not succeed: " url))))

(defn- report! [before target]
  (let [after (release)]
    (if (and (= (:built after) target)
             (not= (:publishedAt after) (:publishedAt before)))
      (println (str "Published " (:name after) " from " (short-id target) ": " (:url after) "\n"
                    "The in-app updater will offer it on its next check, "
                    "or now via Agents ▸ Check for Updates…"))
      (fail "The run finished without replacing the release: "
            (if after
              (str (:name after) " is still built from " (short-id (:built after)) ".")
              "there is no nightly release.")
            "\nSee the run's log for why."))))

(defn -main [& _]
  (let [[local subject] (local-main)
        target          (github-main)
        before          (release)]
    (when (not= local target)
      (fail "Local " branch " (" (short-id local) " " subject ") is not what GitHub has ("
            (short-id target) ").\n"
            "Push it first — or fetch, if GitHub is ahead — and run this again."))
    (if (= (:built before) target)
      (println (str (:name before) " is already built from " branch " ("
                    (short-id target) " " subject "): " (:url before)))
      (do (println (str "Publishing " branch " at " (short-id target) " " subject))
          (watch! (dispatch!))
          (report! before target)))))

(when (= *file* (System/getProperty "babashka.file"))
  (apply -main *command-line-args*))
