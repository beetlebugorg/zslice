#pragma once
// Links that open a model: zslice://open?file=<percent-encoded https URL>.
// The rules of a link are in the core (zs_link_check and the other zs_link
// calls, docs/internals/open-links.md). This file adds what needs the
// network of Windows: it resolves the host, checks each address before
// WinHTTP connects to it, and downloads the file.
//
// The caller asks the user before it calls Fetch.
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

    // For a test: another port, and no check of the name before WinHTTP
    // resolves it. The check of each address in WinHTTP stays.
    struct FetchSeam
    {
        unsigned short port = 0;
        bool skip_resolve = false;
    };

    // True for text that starts with the scheme of the app.
    bool IsLink(std::wstring const &text);
    // True for a name that ends in .stl, .3mf, .step, .stp, or .obj.
    bool IsModelName(std::wstring const &name);
    // Reads a link. `why` has the reason when it returns false.
    bool Parse(std::wstring const &text, ModelLink &out, std::string &why);
    // False for a loopback, private, link-local, or multicast address.
    bool IsPublicAddress(sockaddr const *address);
    // Downloads the file. It blocks, so call it on a worker thread.
    Download Fetch(ModelLink const &link, http::CancelPtr cancel, std::function<void(double)> progress, FetchSeam const &seam = {});
}
