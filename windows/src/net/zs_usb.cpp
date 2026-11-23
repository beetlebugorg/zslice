// See zs_usb.h.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "zs_usb.h"

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <algorithm>
#include <chrono>
#include <cstring>
#include <thread>

namespace zs::usb
{
    namespace
    {
        using Clock = std::chrono::steady_clock;

        constexpr size_t max_line = 255;
        constexpr int read_ms = 100;
        constexpr int write_ms = 5000;
        constexpr int progress_ms = 250;
        constexpr int max_nozzles = 16;

        int PortNumber(std::string const &name)
        {
            if (name.size() < 4 || name.size() > 6 || name.compare(0, 3, "COM") != 0 || name[3] == '0')
                return 0;
            int number = 0;
            for (size_t i = 3; i < name.size(); i++)
            {
                if (name[i] < '0' || name[i] > '9')
                    return 0;
                number = number * 10 + (name[i] - '0');
            }
            return number <= 256 ? number : 0;
        }

        std::string ErrorText(DWORD code)
        {
            char text[256] = "";
            DWORD n = ::FormatMessageA(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, nullptr, code, 0, text, sizeof text, nullptr);
            while (n > 0 && (text[n - 1] == '\r' || text[n - 1] == '\n' || text[n - 1] == ' ' || text[n - 1] == '.'))
                n--;
            return n > 0 ? std::string(text, n) : "error " + std::to_string(code);
        }

        class ComPort final : public Port
        {
        public:
            explicit ComPort(HANDLE handle) : handle_(handle) {}
            ~ComPort() override { ::CloseHandle(handle_); }

            bool Write(char const *data, size_t len) override
            {
                size_t at = 0;
                while (at < len)
                {
                    DWORD put = 0;
                    DWORD piece = (DWORD)std::min<size_t>(len - at, 4096);
                    if (!::WriteFile(handle_, data + at, piece, &put, nullptr) || put == 0)
                        return false;
                    at += put;
                }
                return true;
            }

            int Read(char *data, size_t cap, int timeout_ms) override
            {
                if (timeout_ms != timeout_)
                {
                    COMMTIMEOUTS t{};
                    // Returns at the first byte, or at the end of the time.
                    t.ReadIntervalTimeout = MAXDWORD;
                    t.ReadTotalTimeoutMultiplier = MAXDWORD;
                    t.ReadTotalTimeoutConstant = (DWORD)timeout_ms;
                    t.WriteTotalTimeoutConstant = write_ms;
                    if (!::SetCommTimeouts(handle_, &t))
                        return -1;
                    timeout_ = timeout_ms;
                }
                DWORD got = 0;
                if (!::ReadFile(handle_, data, (DWORD)std::min<size_t>(cap, 4096), &got, nullptr))
                    return -1;
                return (int)got;
            }

            void Flush() override { ::PurgeComm(handle_, PURGE_RXCLEAR | PURGE_TXCLEAR); }

        private:
            HANDLE handle_;
            int timeout_ = -1;
        };

        // The lines of the printer, across reads.
        class Answers
        {
        public:
            explicit Answers(Port &port) : port_(port) {}

            // True at a line that starts with "ok". False with `error` set,
            // or with no error after a stop.
            bool WaitOk(std::atomic<bool> const &stop, int answer_ms, std::string &error)
            {
                auto deadline = Clock::now() + std::chrono::milliseconds(answer_ms);
                while (Clock::now() < deadline)
                {
                    if (stop.load())
                        return false;
                    if (at_ >= count_)
                    {
                        int n = port_.Read(buffer_, sizeof buffer_, read_ms);
                        if (n < 0)
                        {
                            error = "The port stopped.";
                            return false;
                        }
                        at_ = 0;
                        count_ = (size_t)n;
                        continue;
                    }
                    char c = buffer_[at_++];
                    if (c != '\n' && c != '\r')
                    {
                        if (line_.size() < max_line)
                            line_.push_back(c);
                        continue;
                    }
                    std::string done;
                    done.swap(line_);
                    if (done.rfind("ok", 0) == 0)
                        return true;
                    if (done.rfind("Error", 0) == 0 || done.rfind("!!", 0) == 0)
                    {
                        error = "The printer said: " + done;
                        return false;
                    }
                }
                error = "The printer did not answer.";
                return false;
            }

        private:
            Port &port_;
            char buffer_[512];
            size_t at_ = 0, count_ = 0;
            std::string line_;
        };
    }

    bool ValidPort(std::string const &name)
    {
        return PortNumber(name) > 0;
    }

    bool ValidBaud(int baud)
    {
        return std::find(std::begin(bauds), std::end(bauds), baud) != std::end(bauds);
    }

    std::vector<std::string> Ports()
    {
        std::vector<std::string> out;
        HKEY key = nullptr;
        if (::RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"HARDWARE\\DEVICEMAP\\SERIALCOMM", 0, KEY_READ, &key) != ERROR_SUCCESS)
            return out;
        for (DWORD i = 0;; i++)
        {
            wchar_t name[256];
            DWORD name_len = 256;
            wchar_t data[32];
            DWORD data_len = sizeof data - sizeof(wchar_t);
            DWORD type = 0;
            LONG rc = ::RegEnumValueW(key, i, name, &name_len, nullptr, &type, reinterpret_cast<BYTE *>(data), &data_len);
            if (rc == ERROR_NO_MORE_ITEMS)
                break;
            if (rc != ERROR_SUCCESS || type != REG_SZ)
                continue;
            data[data_len / sizeof(wchar_t)] = 0;
            std::string port;
            for (wchar_t const *c = data; *c != 0 && *c < 128; c++)
                port.push_back((char)*c);
            if (ValidPort(port))
                out.push_back(port);
        }
        ::RegCloseKey(key);
        std::sort(out.begin(), out.end(), [](std::string const &a, std::string const &b) { return PortNumber(a) < PortNumber(b); });
        out.erase(std::unique(out.begin(), out.end()), out.end());
        return out;
    }

    std::unique_ptr<Port> OpenPort(std::string const &name, int baud, std::string &error)
    {
        if (!ValidPort(name))
        {
            error = "Pick a serial port, for example COM3.";
            return nullptr;
        }
        if (!ValidBaud(baud))
        {
            error = "Pick a speed for the port.";
            return nullptr;
        }
        std::wstring path = L"\\\\.\\" + std::wstring(name.begin(), name.end());
        HANDLE h = ::CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, 0, nullptr);
        if (h == INVALID_HANDLE_VALUE)
        {
            error = "The port " + name + " does not open: " + ErrorText(::GetLastError());
            return nullptr;
        }
        DCB dcb{};
        dcb.DCBlength = sizeof dcb;
        bool ok = ::GetCommState(h, &dcb) != 0;
        if (ok)
        {
            dcb.BaudRate = (DWORD)baud;
            dcb.ByteSize = 8;
            dcb.Parity = NOPARITY;
            dcb.StopBits = ONESTOPBIT;
            dcb.fBinary = TRUE;
            dcb.fParity = FALSE;
            dcb.fOutxCtsFlow = FALSE;
            dcb.fOutxDsrFlow = FALSE;
            dcb.fDsrSensitivity = FALSE;
            // A USB serial board sends only with DTR on.
            dcb.fDtrControl = DTR_CONTROL_ENABLE;
            dcb.fRtsControl = RTS_CONTROL_ENABLE;
            dcb.fOutX = FALSE;
            dcb.fInX = FALSE;
            dcb.fErrorChar = FALSE;
            dcb.fNull = FALSE;
            dcb.fAbortOnError = FALSE;
            ok = ::SetCommState(h, &dcb) != 0;
        }
        if (!ok)
        {
            error = "The port " + name + " did not take the speed: " + ErrorText(::GetLastError());
            ::CloseHandle(h);
            return nullptr;
        }
        return std::make_unique<ComPort>(h);
    }

    namespace
    {
        bool IsDigit(char c)
        {
            return c >= '0' && c <= '9';
        }

        bool IsLetter(char c)
        {
            return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
        }

        // The tool that a line uses, or -1: a line `T<n>`, or the T word of
        // M104 or M109, which heats a nozzle with no tool change. Firmware
        // also reads words with no space between them, as in M104S200T1. A
        // T word past the last tool counts as the last tool.
        int ToolOfLine(char const *text, size_t len)
        {
            if (len >= 2 && len <= 3 && text[0] == 'T')
            {
                int tool = 0;
                for (size_t i = 1; i < len; i++)
                {
                    if (!IsDigit(text[i]))
                        return -1;
                    tool = tool * 10 + (text[i] - '0');
                }
                return tool < max_nozzles ? tool : -1;
            }
            if (len < 6 || (strncmp(text, "M104", 4) != 0 && strncmp(text, "M109", 4) != 0) || IsDigit(text[4]))
                return -1;
            for (size_t i = 4; i + 1 < len; i++)
            {
                if (text[i] != 'T' || IsLetter(text[i - 1]) || !IsDigit(text[i + 1]))
                    continue;
                int tool = 0;
                for (size_t k = i + 1; k < len && IsDigit(text[k]); k++)
                    tool = std::min(tool * 10 + (text[k] - '0'), max_nozzles - 1);
                return tool;
            }
            return -1;
        }

        // The end of a stopped print: the heaters and the fan go off. It
        // sends no move.
        void CoolDown(Port &port, Answers &answers, bool in_flight, Timing const &timing, int nozzles, Result &result)
        {
            result.cancelled = true;
            std::atomic<bool> no_stop{ false };
            std::string error;
            if (in_flight && !answers.WaitOk(no_stop, timing.answer_ms, error))
            {
                result.message = error;
                return;
            }
            std::vector<std::string> commands;
            if (nozzles <= 1)
                commands.push_back("M104 S0\n");
            else
                for (int n = 0; n < nozzles; n++)
                    commands.push_back("M104 T" + std::to_string(n) + " S0\n");
            commands.push_back("M140 S0\n");
            commands.push_back("M107\n");
            for (std::string const &command : commands)
            {
                if (!port.Write(command.data(), command.size()))
                {
                    result.message = "The port stopped.";
                    return;
                }
                if (!answers.WaitOk(no_stop, timing.cool_ms, error))
                {
                    result.message = error;
                    return;
                }
            }
            result.cooled = true;
            result.message = "The printer turned off the heaters and the fan.";
        }
    }

    Result Stream(Port &port, std::string const &gcode, std::atomic<bool> const &stop, std::function<void(double)> const &progress, Timing timing, int nozzles)
    {
        nozzles = std::clamp(nozzles, 1, max_nozzles);
        Result result;
        // Most boards restart when the port opens: wait, and drop their
        // start text.
        auto settled = Clock::now() + std::chrono::milliseconds(timing.settle_ms);
        while (Clock::now() < settled)
        {
            if (stop.load())
            {
                result.cancelled = true;
                result.message = "Stopped before the first command.";
                return result;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(std::min(timing.settle_ms, 20)));
        }
        port.Flush();
        Answers answers(port);
        size_t pos = 0;
        auto last = Clock::time_point{};
        while (pos < gcode.size())
        {
            if (stop.load())
            {
                if (result.sent)
                    CoolDown(port, answers, false, timing, nozzles, result);
                else
                {
                    result.cancelled = true;
                    result.message = "Stopped before the first command.";
                }
                return result;
            }
            size_t nl = gcode.find('\n', pos);
            size_t end = nl == std::string::npos ? gcode.size() : nl;
            // The command with no comment and no spaces around it.
            size_t cut = gcode.find(';', pos);
            if (cut == std::string::npos || cut > end)
                cut = end;
            while (cut > pos && (gcode[cut - 1] == ' ' || gcode[cut - 1] == '\r' || gcode[cut - 1] == '\t'))
                cut--;
            size_t start = pos;
            while (start < cut && (gcode[start] == ' ' || gcode[start] == '\t'))
                start++;
            pos = end + 1;
            if (cut <= start)
                continue;
            // A tool that the file selects or heats cools on a stop too.
            nozzles = std::max(nozzles, ToolOfLine(gcode.data() + start, cut - start) + 1);
            std::string line = gcode.substr(start, cut - start);
            line.push_back('\n');
            if (!port.Write(line.data(), line.size()))
            {
                result.message = "The port stopped.";
                return result;
            }
            result.sent = true;
            std::string error;
            if (!answers.WaitOk(stop, timing.answer_ms, error))
            {
                if (error.empty())
                    CoolDown(port, answers, true, timing, nozzles, result);
                else
                    result.message = error;
                return result;
            }
            auto now = Clock::now();
            if (progress && now - last >= std::chrono::milliseconds(progress_ms))
            {
                last = now;
                progress(std::min(1.0, (double)pos / (double)gcode.size()));
            }
        }
        if (progress)
            progress(1.0);
        result.ok = true;
        result.message = "The printer took each command.";
        return result;
    }
}
