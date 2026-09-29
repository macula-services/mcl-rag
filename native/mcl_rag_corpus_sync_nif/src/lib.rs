//! mcl_rag_corpus_sync_nif
//!
//! Rustler NIF backing the corpus git-sync gen_server. Given a repo's
//! URL and a local path, clones it if the path isn't a checkout yet;
//! otherwise fetches `origin` for the checkout's current branch and
//! fast-forwards it. Entirely via vendored libgit2 (statically linked
//! at build time) -- no `git` binary needed on the host or in the
//! container at runtime. Replaces an earlier bash-script-on-a-
//! systemd-timer design that only handled the fetch/fast-forward half
//! and assumed the checkout already existed.
//!
//! Deliberately `--ff-only` in spirit: a real merge is never
//! attempted. A diverged history is reported as `not_fast_forward`
//! and left untouched, the same safety property `git pull --ff-only`
//! has.
//!
//! HTTPS only (mirrors this fleet's actual clone convention -- see
//! `macula-demo/infrastructure/gitops/README.md`'s enrollment step).
//! No SSH transport, no credentials callback: a private repo needing
//! auth is out of scope until something here actually needs one.
//!
//! Trusts each path via `safe.directory` (git's own CVE-2022-24765
//! mitigation config, added to libgit2 too) rather than disabling
//! libgit2's ownership check globally: every path this NIF touches is
//! a bind-mounted host directory owned by the host's own user, not the
//! container's runtime UID, so `Repository::open` refuses it by
//! default. Verified live (and reproduced in an isolated container to
//! confirm the fix, not just the symptom): without this, every call
//! failed with "repository path '/corpus' is not owned by current
//! user" -- a container reading its own operator's bind mount, not an
//! untrusted repo. `safe.directory` scopes trust to the exact
//! configured paths rather than turning the check off process-wide
//! (`git2::opts::set_verify_owner_validation(false)` was tried first
//! and also works, but disables the CVE-2022-24765 protection for
//! every path this NIF will ever touch, not just the ones it's
//! actually configured for -- narrower is better with no extra cost
//! here). Idempotent per path (a `Mutex<HashSet>` guard, not a
//! `set_multivar` call every tick forever): `safe.directory` is a
//! multivar with no natural "already present" semantics of its own,
//! and this NIF's own caller re-syncs the same handful of paths every
//! 2 minutes for the life of the process.

use git2::{AnnotatedCommit, FetchOptions, Reference, Repository};
use std::collections::HashSet;
use std::path::Path;
use std::sync::Mutex;

static TRUSTED_PATHS: Mutex<Option<HashSet<String>>> = Mutex::new(None);

fn ensure_path_trusted(path: &str) -> Result<(), SyncError> {
    let mut guard = TRUSTED_PATHS.lock().unwrap();
    let seen = guard.get_or_insert_with(HashSet::new);
    if seen.contains(path) {
        return Ok(());
    }
    let mut cfg = git2::Config::open_default()?.open_global()?;
    cfg.set_multivar("safe.directory", "^$", path)?;
    seen.insert(path.to_string());
    Ok(())
}

pub enum Status {
    Cloned,
    UpToDate,
    FastForwarded { from: String, to: String },
}

pub enum SyncError {
    NotFastForward,
    Git(String),
}

impl From<git2::Error> for SyncError {
    fn from(e: git2::Error) -> Self {
        SyncError::Git(e.message().to_string())
    }
}

/// Ensures `path` is a checkout of `url` and current with it: clones if
/// `path` has no `.git` yet (checking out `branch` if non-empty, else
/// the remote's own default branch), otherwise fetches+fast-forwards
/// whatever branch is already checked out (existing checkouts are
/// never switched to a different branch by a config change -- that's
/// a rarer, deliberate operator action, not something to do silently
/// mid-poll-loop).
pub fn clone_or_sync(url: &str, path: &str, branch: &str) -> Result<Status, SyncError> {
    ensure_path_trusted(path)?;
    if Path::new(path).join(".git").is_dir() {
        sync_inner(path)
    } else {
        clone_inner(url, path, branch)
    }
}

fn clone_inner(url: &str, path: &str, branch: &str) -> Result<Status, SyncError> {
    let mut builder = git2::build::RepoBuilder::new();
    if !branch.is_empty() {
        builder.branch(branch);
    }
    builder.clone(url, Path::new(path))?;
    Ok(Status::Cloned)
}

fn sync_inner(path: &str) -> Result<Status, SyncError> {
    let repo = Repository::open(path)?;
    let branch_name = current_branch_name(&repo)?;

    fetch_origin(&repo, &branch_name)?;

    let fetch_commit = fetch_head_commit(&repo)?;
    let before = repo.head()?.peel_to_commit()?.id().to_string();

    let analysis = repo.merge_analysis(&[&fetch_commit])?;
    if analysis.0.is_up_to_date() {
        return Ok(Status::UpToDate);
    }
    if !analysis.0.is_fast_forward() {
        return Err(SyncError::NotFastForward);
    }

    fast_forward(&repo, &branch_name, &fetch_commit)?;
    let after = fetch_commit.id().to_string();
    Ok(Status::FastForwarded { from: before, to: after })
}

fn current_branch_name(repo: &Repository) -> Result<String, SyncError> {
    let head = repo.head()?;
    head.shorthand()
        .map(|s| s.to_string())
        .ok_or_else(|| SyncError::Git("HEAD is not a valid UTF-8 branch name".to_string()))
}

fn fetch_origin(repo: &Repository, branch_name: &str) -> Result<(), SyncError> {
    let mut remote = repo.find_remote("origin")?;
    let mut opts = FetchOptions::new();
    remote.fetch(&[branch_name], Some(&mut opts), None)?;
    Ok(())
}

fn fetch_head_commit(repo: &Repository) -> Result<AnnotatedCommit<'_>, SyncError> {
    let fetch_head = repo.find_reference("FETCH_HEAD")?;
    Ok(repo.reference_to_annotated_commit(&fetch_head)?)
}

fn fast_forward(
    repo: &Repository,
    branch_name: &str,
    fetch_commit: &AnnotatedCommit,
) -> Result<(), SyncError> {
    let refname = format!("refs/heads/{branch_name}");
    let mut reference: Reference = repo.find_reference(&refname)?;
    reference.set_target(
        fetch_commit.id(),
        &format!("fast-forward: {refname} -> {}", fetch_commit.id()),
    )?;
    repo.set_head(&refname)?;
    repo.checkout_head(Some(git2::build::CheckoutBuilder::default().force()))?;
    Ok(())
}

// The wrapper below pulls in `enif_*` symbols that only exist once this is
// `dlopen`'d into a running BEAM (via `erlang:load_nif/2`) -- `cargo test`
// builds a standalone executable with no BEAM to provide them, so linking
// a test binary that includes it fails outright. Gated out of `cfg(test)`
// entirely: the pure git2 logic above is what the tests below exercise;
// real coverage of the wrapper itself happens on the Erlang side once
// loaded for real.
#[cfg(not(test))]
mod nif {
    use super::{Status, SyncError};
    use rustler::{Encoder, Env, NifResult, Term};

    mod atoms {
        rustler::atoms! {
            ok,
            error,
            cloned,
            up_to_date,
            fast_forwarded,
            not_fast_forward,
            git_error,
        }
    }

    #[rustler::nif(schedule = "DirtyIo")]
    fn clone_or_sync<'a>(env: Env<'a>, url: String, path: String, branch: String) -> NifResult<Term<'a>> {
        Ok(match super::clone_or_sync(&url, &path, &branch) {
            Ok(Status::Cloned) => (atoms::ok(), atoms::cloned()).encode(env),
            Ok(Status::UpToDate) => (atoms::ok(), atoms::up_to_date()).encode(env),
            Ok(Status::FastForwarded { from, to }) => {
                (atoms::ok(), (atoms::fast_forwarded(), from, to)).encode(env)
            }
            Err(SyncError::NotFastForward) => {
                (atoms::error(), atoms::not_fast_forward()).encode(env)
            }
            Err(SyncError::Git(msg)) => (atoms::error(), (atoms::git_error(), msg)).encode(env),
        })
    }

    rustler::init!("mcl_rag_corpus_sync_nif");
}

#[cfg(test)]
mod tests {
    use super::*;
    use git2::{Repository, Signature};
    use std::fs;
    use std::path::{Path, PathBuf};

    struct TempDir(PathBuf);

    // cargo test runs test functions concurrently by default -- a
    // check-then-create loop keyed only on pid can hand two threads the
    // same "unique" path in the gap between the check and the create.
    // A single process-wide atomic counter has no such gap.
    static NEXT_ID: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

    impl TempDir {
        fn new(label: &str) -> Self {
            let n = NEXT_ID.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            let path = std::env::temp_dir().join(format!(
                "mcl_rag_corpus_sync_nif-{label}-{}-{n}",
                std::process::id()
            ));
            fs::create_dir_all(&path).unwrap();
            TempDir(path)
        }
        fn path(&self) -> &Path {
            &self.0
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn commit_file(repo: &Repository, name: &str, contents: &str, message: &str) -> git2::Oid {
        let workdir = repo.workdir().unwrap().to_path_buf();
        fs::write(workdir.join(name), contents).unwrap();
        let mut index = repo.index().unwrap();
        index.add_path(Path::new(name)).unwrap();
        index.write().unwrap();
        let tree_id = index.write_tree().unwrap();
        let tree = repo.find_tree(tree_id).unwrap();
        let sig = Signature::now("Test", "test@example.com").unwrap();
        let parents: Vec<git2::Commit> = match repo.head() {
            Ok(head) => vec![head.peel_to_commit().unwrap()],
            Err(_) => vec![],
        };
        let parent_refs: Vec<&git2::Commit> = parents.iter().collect();
        repo.commit(Some("HEAD"), &sig, &sig, message, &tree, &parent_refs)
            .unwrap()
    }

    /// Sets up a bare "remote" repo plus a working "origin-side" checkout
    /// that pushes into it (bare repos have no working tree of their own,
    /// so commits have to be made in a separate clone and pushed).
    fn setup_remote_with_content() -> (TempDir, TempDir) {
        let remote_dir = TempDir::new("remote-bare");
        Repository::init_bare(remote_dir.path()).unwrap();

        let origin_dir = TempDir::new("origin-workdir");
        let origin_repo = Repository::init(origin_dir.path()).unwrap();
        commit_file(&origin_repo, "corpus.md", "# v1\n", "initial commit");
        {
            let mut remote = origin_repo
                .remote("origin", remote_dir.path().to_str().unwrap())
                .unwrap();
            remote.push(&["refs/heads/master:refs/heads/master"], None).unwrap();
        }

        (remote_dir, origin_dir)
    }

    /// Same as `setup_remote_with_content` plus an already-cloned local
    /// checkout -- what the three tests below exercise `clone_or_sync`'s
    /// fetch+fast-forward branch against (the NIF under test operates on
    /// `local_clone_dir`, matching what a real corpus checkout on a beam
    /// host already is by the time this ever runs against it).
    fn setup() -> (TempDir, TempDir, TempDir) {
        let (remote_dir, origin_dir) = setup_remote_with_content();

        let local_dir = TempDir::new("local-clone");
        fs::remove_dir(local_dir.path()).unwrap(); // clone_into needs to create it itself
        Repository::clone(remote_dir.path().to_str().unwrap(), local_dir.path()).unwrap();

        (remote_dir, origin_dir, local_dir)
    }

    fn push_new_commit(origin_dir: &TempDir, contents: &str) -> String {
        let origin_repo = Repository::open(origin_dir.path()).unwrap();
        let oid = commit_file(&origin_repo, "corpus.md", contents, "update");
        let mut remote = origin_repo.find_remote("origin").unwrap();
        remote.push(&["refs/heads/master:refs/heads/master"], None).unwrap();
        oid.to_string()
    }

    fn head_of(origin_dir: &TempDir) -> String {
        let repo = Repository::open(origin_dir.path()).unwrap();
        let id = repo.head().unwrap().peel_to_commit().unwrap().id().to_string();
        id
    }

    fn read(dir: &TempDir) -> String {
        fs::read_to_string(dir.path().join("corpus.md")).unwrap()
    }

    // The HTTPS transport, against GitHub's own long-stable smoke-test repo at
    // its long-stable commit: `default-features = false' on git2 once dropped
    // the TLS backend and only a real https URL showed it.
    #[test]
    fn clones_a_real_repo_over_https_at_its_pinned_commit() {
        let local_dir = TempDir::new("https-clone-target");
        fs::remove_dir(local_dir.path()).unwrap();
        let path = local_dir.path().to_str().unwrap().to_string();
        let pin = "7fd1a60b01f91b314f59955a4e4d4e80d8edf11d";
        match sync_to_commit("https://github.com/octocat/Hello-World.git", &path, "master", pin) {
            Ok(Status::Moved { to, .. }) => assert_eq!(to, pin),
            Ok(Status::UpToDate) => panic!("expected a fresh checkout"),
            Err(SyncError::Git(msg)) => panic!("HTTPS clone failed: {msg}"),
            Err(SyncError::CommitNotOnBranch) => panic!("the pin is on master"),
        }
    }

    #[test]
    fn a_fresh_clone_is_checked_out_at_the_pinned_commit() {
        let (remote, origin) = setup_remote_with_content();
        let pin = head_of(&origin);
        push_new_commit(&origin, "# v2\n");
        let local = TempDir::new("fresh-clone-target");
        fs::remove_dir(local.path()).unwrap();
        let url = remote.path().to_str().unwrap().to_string();
        let path = local.path().to_str().unwrap().to_string();
        match sync_to_commit(&url, &path, "master", &pin) {
            Ok(Status::Moved { to, .. }) => assert_eq!(to, pin),
            _ => panic!("expected the checkout to move to the pin"),
        }
        assert_eq!(read(&local), "# v1\n");
    }

    // THE POINT OF THE PIN: a push to the branch is not ingested.
    #[test]
    fn a_moved_branch_head_is_not_followed() {
        let (remote, origin, local) = setup();
        let pin = head_of(&origin);
        let url = remote.path().to_str().unwrap().to_string();
        let path = local.path().to_str().unwrap().to_string();
        push_new_commit(&origin, "# pushed, not reviewed\n");
        match sync_to_commit(&url, &path, "master", &pin) {
            Ok(Status::UpToDate) => {}
            _ => panic!("expected the checkout to stay on the pin"),
        }
        assert_eq!(read(&local), "# v1\n");
    }

    #[test]
    fn a_new_pin_moves_the_checkout() {
        let (remote, origin, local) = setup();
        let old = head_of(&origin);
        let new = push_new_commit(&origin, "# v2\n");
        let url = remote.path().to_str().unwrap().to_string();
        let path = local.path().to_str().unwrap().to_string();
        match sync_to_commit(&url, &path, "master", &new) {
            Ok(Status::Moved { from, to }) => {
                assert_eq!(from, old);
                assert_eq!(to, new);
            }
            _ => panic!("expected the checkout to move to the new pin"),
        }
        assert_eq!(read(&local), "# v2\n");
        match sync_to_commit(&url, &path, "master", &new) {
            Ok(Status::UpToDate) => {}
            _ => panic!("expected UpToDate on the second sync"),
        }
    }

    // A commit the branch does not contain (another branch, a fork, a typo
    // of a real sha) is refused, and the checkout stays where it was.
    #[test]
    fn a_commit_not_on_the_branch_is_refused() {
        let (remote, origin, local) = setup();
        let url = remote.path().to_str().unwrap().to_string();
        let path = local.path().to_str().unwrap().to_string();
        let stray = "0123456789abcdef0123456789abcdef01234567";
        let _ = origin;
        match sync_to_commit(&url, &path, "master", stray) {
            Err(SyncError::CommitNotOnBranch) => {}
            _ => panic!("expected CommitNotOnBranch"),
        }
        assert_eq!(read(&local), "# v1\n");
    }

    // A local edit in the checkout (it is ours, not a working copy) is
    // replaced by the pinned commit's content.
    #[test]
    fn a_local_edit_is_replaced_by_the_pinned_content() {
        let (remote, origin, local) = setup();
        let pin = head_of(&origin);
        fs::write(local.path().join("corpus.md"), "# edited in place\n").unwrap();
        let url = remote.path().to_str().unwrap().to_string();
        let path = local.path().to_str().unwrap().to_string();
        let _ = sync_to_commit(&url, &path, "master", &pin);
        assert_eq!(read(&local), "# v1\n");
    }
}
