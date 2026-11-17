# Privacy

zslice collects no data about you. It has no analytics, no tracking, no cookies, and no ads.

## The web app

The web app at [zslice.beetlebug.org](https://zslice.beetlebug.org/) runs in your browser.

- **Your files stay on your computer.** The app reads a model in your browser and slices it there, in WebAssembly. It sends your models, your settings, and your G-code to no server.
- **Nothing from other sites.** The pages load no scripts, fonts, images, or styles from other sites. The app makes no request that you did not ask for.
- **Requests that you start.** The app connects to another address only when you tell it to:
  - the address of a model that you give in the page address (`?model=`), to load that model;
  - the address of your printer, to send it a print, or to test the connection. The API key of the printer goes only to the printer;
  - GitHub, when you open a project from a GitHub repository (the Project tab). The app reads the repository from `api.github.com` (the commit and the list of files), and the files that a plate needs from `raw.githubusercontent.com` (and `media.githubusercontent.com` for a file in Git LFS). It sends no login and no data of yours. GitHub sees these requests, as it sees each visit to a repository, under the [GitHub Privacy Statement](https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement).
- **What your browser keeps.** The app keeps your settings, your printers (with their addresses and API keys), the layout of the window (for example the width of the panel), the project you opened (its printdeck.yml, the counts, and the status of each plate), and the plate you work on (so a refresh keeps your work) in the storage of your browser. This storage is on your computer only, and the app sends it nowhere. To remove it, clear the site data of zslice.beetlebug.org in your browser.
- **The host, and no logs.** Amazon Web Services serves the site: the files are in Amazon S3, and Amazon CloudFront sends them to your browser. We turned off all request logs: CloudFront keeps no access logs for us, and S3 keeps no access logs. So we do not record your IP address, the pages you open, or when. Amazon handles each request to send you the page, under the [AWS Privacy Notice](https://aws.amazon.com/privacy/), and can keep data for its own operation of the service, as each host does. We get no data about you from Amazon: only the totals of the site (the number of requests and bytes), with nothing about one visitor.
- **The headers of the page.** The site sends headers that keep other sites out of the page (cross-origin isolation). They also stop the page from loading scripts, styles, or images from another site.

## The documentation

The documentation pages are on the same site and follow the same rules: no analytics, no cookies, and nothing from other sites. They use the fonts of your system.

## The desktop app

The desktop app sends no data about you. It connects only to:

- the printers that you set up (printdeck, OctoPrint, Moonraker, PrusaLink), to send prints and read their state;
- your local network, to find printers (mDNS, when you open the printer list). These packets stay on your network;
- GitHub, when you open a project from a GitHub repository (the Project tab). The app makes the same requests as the web app: the commit and the list of files from `api.github.com`, and the files that a plate needs from `raw.githubusercontent.com` (and `media.githubusercontent.com` for a file in Git LFS). It sends no login and no data of yours. After a restart, it gets the list of files of the open project again, at the same commit. GitHub sees these requests under the [GitHub Privacy Statement](https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement).

It keeps its settings in your user folder (`~/.config/zslice` on Linux). The open project (its printdeck.yml, the counts, and the status of each plate) is in `project.json` there.

## Questions

Open an issue on [GitHub](https://github.com/beetlebugorg/zslice/issues).
