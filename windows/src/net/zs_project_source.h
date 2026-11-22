#pragma once
// The files of a printdeck.yml project: a public GitHub repository at one
// commit, or a folder on this computer.
//
// GitHub is the only network use of a project, with these rules:
// - A request goes over https to github.com, api.github.com,
//   raw.githubusercontent.com, or media.githubusercontent.com (Git LFS).
//   Each redirect passes the same check, and the peer must be a public
//   address.
// - A request has no key, no token, no cookie, and no login. It uses its own
//   WinHTTP session, so the code of the printers cannot add a header.
// - Each file has a size limit, and one load has a limit for all its files.
//
// A read accepts only a path of the list of the source: the blobs of the tree,
// or the files that the walk of the folder found. The walk skips links and
// junctions, so a path of printdeck.yml cannot leave the folder.
//
// The requests are those of web/app/project.js and
// linux/src/net/project-source.c: the GitHub REST API and the Git LFS pointer
// file. See docs/references/formats-and-protocols.md.
//
// It has no WinRT, so a test program can link it. The calls block, so call
// them on a worker thread.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include <cstddef>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "zs_http.h"

namespace zs::project
{
    // One file of a project.
    size_t const max_file = size_t(256) << 20;
    // All files of one load of the plates.
    size_t const max_total = size_t(1) << 30;
    // One answer of the GitHub API (the list of the files).
    size_t const max_api = size_t(64) << 20;
    // printdeck.yml.
    size_t const max_yml = size_t(4) << 20;
    // The files in the list of a source.
    size_t const max_paths = 200000;

    struct GithubRepo
    {
        std::string owner, repo;
        // A branch, a tag, or a commit. Empty: the default branch.
        std::string ref;
    };

    // Reads "owner/repo", "github.com/owner/repo", or an https address of
    // github.com, also with /tree/<ref>. False for any other text.
    bool ParseGithub(std::string const &text, GithubRepo &out);
    // True for an https URL on port 443 of one of the four GitHub hosts.
    bool IsAllowedUrl(std::string const &url);
    // True for an owner or a repository name that the API can have.
    bool IsRepoName(std::string const &name);
    // True for a commit id: 40 or 64 hex digits.
    bool IsCommit(std::string const &sha);

    class Source
    {
    public:
        enum class Kind
        {
            Github,
            Folder,
        };

        Source();
        ~Source();
        Source(Source const &) = delete;
        Source &operator=(Source const &) = delete;

        Kind kind = Kind::Folder;
        std::string owner, repo, sha;
        // The folder, as the user chose it.
        std::wstring folder;

        bool Has(std::string const &path) const { return paths_.count(path) != 0; }
        // The files under a folder of the repository.
        std::vector<std::string> List(std::string const &folder_path) const;
        // Reads one file of the list. On a failure, `error` has the text
        // for the user. A stopped read returns false with no error.
        bool Read(std::string const &path, std::string &bytes, std::string &error, http::CancelPtr const &cancel);

    private:
        friend std::shared_ptr<Source> OpenGithub(GithubRepo const &, std::string const &, http::CancelPtr const &, std::string &);
        friend std::shared_ptr<Source> OpenFolder(std::wstring const &, http::CancelPtr const &, std::string &);

        bool ReadGithub(std::string const &path, std::string &bytes, std::string &error, http::CancelPtr const &cancel);
        bool ReadFolder(std::string const &path, std::string &bytes, std::string &error);

        std::unordered_set<std::string> paths_;
        // The WinHTTP session of this source (GitHub only).
        void *session_ = nullptr;
        std::mutex lock_;
        std::unordered_map<std::string, std::string> cache_;
        size_t cached_ = 0;
    };

    // The list of the files of a repository. `sha` empty: the commit of
    // ref, or of the default branch. `sha` set: that commit.
    std::shared_ptr<Source> OpenGithub(GithubRepo const &repo, std::string const &sha, http::CancelPtr const &cancel, std::string &error);
    // The list of the files of a folder, with no .git and no links.
    std::shared_ptr<Source> OpenFolder(std::wstring const &folder, http::CancelPtr const &cancel, std::string &error);
}
