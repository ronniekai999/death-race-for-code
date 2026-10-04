import Testing

@testable import AppCore

@Suite struct GitHeadTests {
    /// A file system of named directories and files.
    func disk(directories: Set<String>, files: [String: String]) -> GitHead.FileSystem {
        GitHead.FileSystem(
            entry: { path in
                directories.contains(path) ? .directory : files[path] != nil ? .file : .missing
            },
            contents: { files[$0] })
    }

    @Test func aBranchIsFoundFromAnyDirectoryInside() {
        let fs = disk(
            directories: ["/code/app/.git"], files: ["/code/app/.git/HEAD": "ref: refs/heads/main\n"])
        #expect(GitHead.branch(at: "/code/app", in: fs) == "main")
        #expect(GitHead.branch(at: "/code/app/Sources/Deep/", in: fs) == "main")
        #expect(GitHead.branch(at: "/code", in: fs) == nil)
        #expect(GitHead.branch(at: "/", in: fs) == nil)
    }

    @Test func branchNamesKeepTheirSlashes() {
        let fs = disk(directories: ["/r/.git"], files: ["/r/.git/HEAD": "ref: refs/heads/feature/pit-lane"])
        #expect(GitHead.branch(at: "/r", in: fs) == "feature/pit-lane")
    }

    @Test func aDetachedHeadShowsItsCommit() {
        let fs = disk(directories: ["/r/.git"], files: ["/r/.git/HEAD": "9a1f3c2b7e0d4f1a2b3c4d5e6f708192a3b4c5d6\n"])
        #expect(GitHead.branch(at: "/r", in: fs) == "9a1f3c2")
    }

    @Test func worktreesAndSubmodulesFollowTheirGitFile() {
        let fs = disk(
            directories: ["/r/.git", "/r/.git/worktrees/wt"],
            files: [
                "/wt/.git": "gitdir: /r/.git/worktrees/wt\n",
                "/r/.git/worktrees/wt/HEAD": "ref: refs/heads/hotfix\n",
                "/r/sub/.git": "gitdir: ../.git/modules/sub",
                "/r/.git/modules/sub/HEAD": "ref: refs/heads/main",
            ])
        #expect(GitHead.branch(at: "/wt/src", in: fs) == "hotfix")
        #expect(GitHead.branch(at: "/r/sub", in: fs) == "main")
    }

    @Test func nonsenseHeadsAreNoBranch() {
        #expect(GitHead.describe("") == nil)
        #expect(GitHead.describe("ref:") == nil)
        #expect(GitHead.describe("not a commit") == nil)
        #expect(GitHead.describe("ref: refs/remotes/origin/main") == "refs/remotes/origin/main")
    }

    @Test func pathsAreNormalized() {
        #expect(GitHead.normalized("/a/./b//c/../d/") == "/a/b/d")
        #expect(GitHead.normalized("/../..") == "/")
        #expect(GitHead.parent(of: "/a/b") == "/a")
        #expect(GitHead.parent(of: "/a") == "/")
    }

    @Test func theRealDiskWorks() throws {
        // This repository, from the test file's own directory.
        var directory = #filePath
        while let last = directory.last, last != "/" { directory.removeLast() }
        let branch = GitHead.branch(at: directory)
        // CI checks out a detached commit; a clone has a branch. Either way, something.
        #expect(branch != nil && branch?.isEmpty == false)
    }
}
