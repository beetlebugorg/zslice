# The Windows app

The Windows app is a native app for Windows 10 and 11, on x64 and ARM64. It is in progress. This page describes what it does now.

## Open a model

Press **Open** or Ctrl+O and pick an STL or 3MF file. You can also drop a file on the window, or give a file on the command line. The app slices the model at once, and the status bar shows the layers, the print time, and the filament.

## Look at the slice

| Do this | To |
|---|---|
| Drag with the left button | Turn the view |
| Drag with the right mouse button | Turn the view |
| Click with two fingers on a touchpad and slide | Move the view |
| Drag with the middle button, or hold Shift and drag | Move the view |
| Scroll, or pinch on a touchpad | Zoom |

The slider at the right shows the print up to a layer.

## Set up a printer

At the first start, the app asks for your printer. Type a part of its name, or pick a brand, then click **Next**. Check the name, the nozzle, the filament, and the size. Set the connection, and click **Add printer**.

The top bar has the setup of the plate:

- **The printer menu** switches the printer. It also has **Printer settings and G-code…**, **Manage printers…**, **Connect a printdeck…**, and **Add a printer…**.
- **The filament menu** has a color and a material for each filament. For a printdeck printer, **Use the filaments of** reads the spools that the printer has loaded.
- **The quality menu** lists each quality with its main points.

## Connect a printer

| Connection | What you need |
|---|---|
| printdeck | The address. Tap **Allow** on its screen. |
| OctoPrint | The address, and **Allow** in its web page, or an API key. |
| PrusaLink | The address and its API key. |
| Moonraker (Klipper) | The address. |
| Bambu Lab (LAN mode) | The IP address, the serial number, and the access code. |

The picker finds printers on your network. **Printers** in the top bar shows a card for each printer: its state, its job, its temperatures, its roll, and its camera.

The app reads a Bambu Lab printer and sends it nothing. It shows the JPEG camera of a P1 or an A1. It does not show the H.264 camera of an X1, H2, P2S, or X2D yet.

## Send and export

The **Send** menu has:

- **Upload to** the printer, and **Send all plates**.
- **Export G-code…** and **Export all plates…**.
- **Save the plate as 3MF…** and **Save project…**.

**The Windows app never starts a print.** It uploads the file, and you start the print on the printer.

## Where your settings are

Your printers and profiles are in `%APPDATA%\zslice`. API keys and access codes are encrypted for your Windows account. They are never in a file in plain text.
