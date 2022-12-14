extern crate libc;
use std::fs::{OpenOptions, create_dir_all};
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::process;
use std::time::SystemTime;
use memoize::memoize;
mod lib;
use lib::{Ktestrc, read_lines, ktestrc_read, git_get_commit};

use multimap::MultiMap;
use die::die;

use glob::glob;

#[memoize]
fn get_subtests(test_path: PathBuf) -> Vec<String> {
    let output = std::process::Command::new(&test_path)
        .arg("list-tests")
        .output()
        .expect(&format!("failed to execute process {:?} ", &test_path))
        .stdout;
    let output = String::from_utf8_lossy(&output);

    output
        .split_whitespace()
        .map(|i| i.to_string())
        .collect()
}

fn lockfile_exists(rc: &Ktestrc, commit: &str, test_path: &Path, subtest: &str, create: bool) -> bool {
    let subtest = subtest.replace("/", ".");
    let test_name = test_path.file_stem().unwrap().to_string_lossy();
    let lockfile = rc.ci_output_dir.join(commit)
        .join(format!("{}.{}", test_name, subtest))
        .join("status");

    let timeout = std::time::Duration::from_secs(3600);
    let metadata = std::fs::metadata(&lockfile);

    if let Ok(metadata) = metadata {
        let elapsed = metadata.modified().unwrap()
            .elapsed()
            .unwrap_or(std::time::Duration::from_secs(0));

        if metadata.is_file() &&
           metadata.len() == 0 &&
           elapsed > timeout &&
           std::fs::remove_file(&lockfile).is_ok() {
            eprintln!("Deleted stale lock file {:?}, mtime {:?} now {:?} elapsed {:?})",
                      &lockfile, metadata.modified().unwrap(),
                      SystemTime::now(),
                      elapsed);
        }
    }

    if !create {
        lockfile.exists()
    } else {
        let dir = lockfile.parent().unwrap();
        let r = create_dir_all(dir);
        if let Err(e) = r {
            if e.kind() != ErrorKind::AlreadyExists {
                die!("error creating {:?}: {}", dir, e);
            }
        }

        let r = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&lockfile);
        if let Err(ref e) = r {
            if e.kind() != ErrorKind::AlreadyExists {
                die!("error creating {:?}: {}", lockfile, e);
            }
        }

        r.is_ok()
    }
}

struct TestJob {
    branch:     String,
    commit:     String,
    age:        usize,
    test:       PathBuf,
    subtests:   Vec<String>,
}

fn branch_get_next_test_job(rc: &Ktestrc, repo: &git2::Repository,
                            branch: &str, test_path: &PathBuf) -> Option<TestJob> {
    let mut ret =  TestJob {
        branch:     branch.to_string(),
        commit:     String::new(),
        age:        0,
        test:       test_path.clone(),
        subtests:   Vec::new(),
    };

    let subtests = get_subtests(PathBuf::from(test_path));

    let mut walk = repo.revwalk().unwrap();
    let reference = git_get_commit(&repo, branch.to_string());
    if reference.is_err() {
        eprintln!("branch {} not found", branch);
        return None;
    }
    let reference = reference.unwrap();

    if let Err(e) = walk.push(reference.id()) {
        eprintln!("Error walking {}: {}", branch, e);
        return None;
    }

    for commit in walk
            .filter_map(|i| i.ok())
            .filter_map(|i| repo.find_commit(i).ok()) {
        let commit = commit.id().to_string();
        ret.commit = commit.clone();

        for subtest in subtests.iter() {
            if !lockfile_exists(rc, &commit, &test_path, subtest, false) {
                ret.subtests.push(subtest.to_string());
                if ret.subtests.len() > 20 {
                    break;
                }
            }
        }

        if !ret.subtests.is_empty() {
            return Some(ret);
        }

        ret.age += 1;
    }

    None
}

fn get_best_test_job(rc: &Ktestrc, repo: &git2::Repository,
                     branch_tests: &MultiMap<String, PathBuf>) -> Option<TestJob> {
    let mut ret: Option<TestJob> = None;

    for (branch, testvec) in branch_tests.iter_all() {
        for test in testvec {
            let job = branch_get_next_test_job(rc, repo, branch, test);

            let ret_age = ret.as_ref().map_or(std::usize::MAX, |x| x.age);
            let job_age = job.as_ref().map_or(std::usize::MAX, |x| x.age);

            if job_age < ret_age {
                ret = job;
            }
        }
    }

    ret
}

fn create_job_lockfiles(rc: &Ktestrc, mut job: TestJob) -> Option<TestJob> {
    job.subtests = job.subtests.iter()
        .filter(|i| lockfile_exists(rc, &job.commit, &Path::new(&job.test), &i, true))
        .map(|i| i.to_string())
        .collect();

    if !job.subtests.is_empty() { Some(job) } else { None }
}

fn main() {
    let ktestrc = ktestrc_read();
    if let Err(e) = ktestrc {
        eprintln!("could not read config; {}", e);
        process::exit(1);
    }
    let ktestrc = ktestrc.unwrap();

    let repo = git2::Repository::open(&ktestrc.ci_linux_repo);
    if let Err(e) = repo {
        eprintln!("Error opening {:?}: {}", ktestrc.ci_linux_repo, e);
        eprintln!("Please specify correct ci_linux_repo");
        process::exit(1);
    }
    let repo = repo.unwrap();

    let _r = std::process::Command::new("flock")
        .arg("--nonblock")
        .arg(".git_fetch.lock")
        .arg("git").arg("fetch").arg("--all")
        .current_dir(&ktestrc.ci_linux_repo)
        .output();

    let lines = read_lines(&ktestrc.ci_branches_to_test);
    if let Err(e) = lines {
        eprintln!("Error opening {:?}: {}", ktestrc.ci_branches_to_test, e);
        eprintln!("Please specify correct ci_branches_to_test");
        process::exit(1);
    }
    let lines = lines.unwrap();

    let lines = lines.filter_map(|i| i.ok());

    let mut branch_tests: MultiMap<String, PathBuf > = MultiMap::new();

    for l in lines {
        let l: Vec<_> = l.split_whitespace().take(2).collect();

        if l.len() == 2 {
            let branch  = l[0];
            let test    = l[1];

            for i in glob(test).expect(&format!("No tests matching {}", test))
                               .filter_map(|i| i.ok()) {
                branch_tests.insert(branch.to_string(), i);
            }
        }
    }

    let mut job: Option<TestJob>;

    loop {
        job = get_best_test_job(&ktestrc, &repo, &branch_tests);

        if job.is_none() {
            break;
        }

        job = create_job_lockfiles(&ktestrc, job.unwrap());
        if let Some(job) = job {
            print!("{} {} {}", job.branch, job.commit, job.test.display());
            for t in job.subtests {
                print!(" {}", t);
            }
            println!("");
            break;
        }
    }

}
