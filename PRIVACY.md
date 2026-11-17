# Privacy

zslice collects no data about you. It has no analytics, no tracking, no cookies, and no ads.

## The web app

The web app at [zslice.beetlebug.org](https://zslice.beetlebug.org/) runs in your browser.

- **Your files stay on your computer.** The app reads a model in your browser and slices it there, in WebAssembly. It sends your models, your settings, and your G-code to no server.
- **Nothing from other sites.** The pages load no scripts, fonts, images, or styles from other sites. The app makes no request that you did not ask for.
- **Two requests that you start.** The app connects to another address only when you tell it to:
  - the address of a model that you give in the page address (`?model=`), to load that model;
  - the address of your printer, to send it a print.
- **What your browser keeps.** The app keeps your settings, your printers, the layout of the window (for example the width of the panel), and the plate you work on (so a refresh keeps your work) in the storage of your browser. This storage is on your computer only, and the app sends it nowhere. To remove it, clear the site data of zslice.beetlebug.org in your browser.
- **The host.** GitHub Pages serves the site. GitHub can log the requests to its servers, for example the IP address of your computer, under the [GitHub Privacy Statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement). zslice gets no data from these logs.

## The documentation

The documentation pages are on the same site and follow the same rules: no analytics, no cookies, and nothing from other sites. They use the fonts of your system.

## The desktop app

The desktop app sends no data about you. It connects only to:

- the printers that you set up (printdeck, OctoPrint, Moonraker, PrusaLink), to send prints and read their state;
- your local network, to find printers (mDNS, when you open the printer list). These packets stay on your network.

It keeps its settings in your user folder (`~/.config/zslice` on Linux).

## Questions

Open an issue on [GitHub](https://github.com/beetlebugorg/zslice/issues).
