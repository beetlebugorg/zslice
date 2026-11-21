#pragma once
// Links that open a model: zslice://open?file=<percent-encoded https URL>,
// the form of the "Open in slicer" links of model sites. This file takes
// only the shape of the link from PrusaSlicer (docs/references/).
//
// Any web page can start such a link, so the rules are strict:
// - The file comes over https, from a public host name. An address, a local
//   name, a user name in the URL, and another port are refused.
// - Each redirect passes the same rules, and the connection must end at a
//   public address, so a link cannot reach a device on the local network.
// - The request sends no cookie and no key, and the download has a size limit.
// - The caller asks the user before it calls Fetch.
//
// It has no WinRT, so a test program can link it.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include <functional>
#include <string>

#include "zs_http.h"

struct sockaddr;

namespace zs::openlink
{
    // The largest file that a link can download.
    size_t const max_download = size_t(512) << 20;

    struct ModelLink
    {
        std::string url;
        std::string host;
        // The file name in the URL, or empty if it has none.
        std::wstring name;
    };

    struct Download
    {
        std::string bytes;
        std::wstring name;
        std::string error;
        bool cancelled = false;
    };

    // True for text that starts with the scheme of the app.
    bool IsLink(std::wstring const &text);
    // True for a name that ends in .stl, .3mf, .step, .stp, or .obj.
    bool IsModelName(std::wstring const &name);
    // Reads a link. `why` says what is wrong when it returns false.
    bool Parse(std::wstring const &text, ModelLink &out, std::string &why);
    // False for a loopback, private, link-local, or multicast address.
    bool IsPublicAddress(sockaddr const *address);
    // Downloads the file. It blocks, so call it on a worker thread.
    Download Fetch(ModelLink const &link, http::CancelPtr cancel, std::function<void(double)> progress);
}
