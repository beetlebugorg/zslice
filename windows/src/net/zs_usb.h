#pragma once
// A printer on a USB serial port.
//
// A serial port has no upload. Each line of G-code goes to the printer and
// runs, so Stream IS a print. The caller runs it only after a fresh yes of
// the user, and never from a timer or a retry.
//
// The protocol is the host protocol of Marlin and RepRap firmware: one
// command, then wait for a line that starts with "ok". The flow follows
// linux/src/net/printer-link.c. See docs/references/klipper-marlin-firmware.md.
//
// An open can restart the printer board, so nothing here opens a port that
// the user did not pick. Ports reads the names from the registry and opens
// none of them. OpenPort accepts only a name of the form COMn.
//
// Each call blocks, so it runs on a worker thread. It has no WinRT.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include <atomic>
#include <cstddef>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace zs::usb
{
    constexpr int default_baud = 250000;
    // The speeds of the connection list, in the order of the GTK app.
    constexpr int bauds[] = { 250000, 115200, 230400, 500000, 1000000, 57600 };

    // True for COM1 to COM256, with no other text.
    bool ValidPort(std::string const &name);
    bool ValidBaud(int baud);
    // The serial ports of this computer, by number. No port opens.
    std::vector<std::string> Ports();

    class Port
    {
    public:
        virtual ~Port() = default;
        // False when the port stopped.
        virtual bool Write(char const *data, size_t len) = 0;
        // The count of bytes, 0 when none came in `timeout_ms`, or -1 when
        // the port stopped.
        virtual int Read(char *data, size_t cap, int timeout_ms) = 0;
        // Drops what waits in both directions.
        virtual void Flush() = 0;
    };

    // Opens a port that the user picked. Most boards restart at this call.
    std::unique_ptr<Port> OpenPort(std::string const &name, int baud, std::string &error);

    struct Result
    {
        bool ok = false;
        bool cancelled = false;
        std::string message;
    };

    struct Timing
    {
        // The wait for a board that restarted at the open.
        int settle_ms = 2000;
        // The longest wait for one "ok": a long move or a heat-up.
        int answer_ms = 600000;
    };

    // Sends each command of the G-code and waits for its "ok". `stop` ends
    // it before the next command. It sends nothing more after a stop.
    Result Stream(Port &port, std::string const &gcode, std::atomic<bool> const &stop, std::function<void(double)> const &progress, Timing timing = {});
}
