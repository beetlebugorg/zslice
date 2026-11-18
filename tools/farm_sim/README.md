# The farm simulator

`farm_sim.py` runs a print farm on your computer, for the tests of the
zslice apps: 50 printers (by default) of many brands and kinds, each an HTTP
server on 127.0.0.1 that answers as the real printer does. It needs only
Python 3.

```sh
python3 -I tools/farm_sim/farm_sim.py --printers 50 --speed 60
```

- **The printers.** printdeck (Prusa, LulzBot), Moonraker (Creality, Voron,
  Elegoo), OctoPrint (Sovol, Anycubic), and resin printers. Each has its bed,
  its nozzle, its speed, and its roll. A few never answer. The API key of
  each is `farm` (`--key`).
- **The clock.** `--speed 60` runs an hour of the farm in a minute.
- **The prints.** A print heats, prints, and then waits on the bed until a
  person clears it. Some fail (`--fail-rate`), and a few pause for a runout.
  At the start, `--busy` of the farm prints or waits on the bed.
- **printdeck.** A printdeck never starts a print by itself, as the real one:
  a file sent to it waits in its queue (`/api/plugin/printdeck/queue`) until
  a person at the deck presses Print. OctoPrint and Moonraker start a print
  sent with `print=true`.
- **The operator.** The people of the farm clear the beds and press Print, 5
  to 45 minutes after it is due. `--no-operator` leaves that to you.
- **The orders.** Orders come in at random (`--order-every`): a model of
  `../printdeck` and a count.

## Use it with the macOS app

The simulator writes `fleet.json`. In the app, choose File > Add Printers
from a Fleet File, and pick it; or start the app with
`ZSLICE_FLEET=fleet.json`. The Printers page (Option-Command-P) then shows
the 50 printers, and macOS notifies you when a print is ready to collect or
fails.

## The control API

On 127.0.0.1:8800 (`--control`). It answers only a client on this computer: the Host header must be 127.0.0.1 or localhost, and a request with an Origin header (from a web page) gets 403.

| Request | What it does |
|---|---|
| `GET /farm` | All printers, their states, and the counts. |
| `GET /orders`, `GET /events` | The orders, and the last events. |
| `POST /farm/<id>/clear` | A person takes the print off the bed. |
| `POST /farm/<id>/press` | A person presses Print on the deck. |
| `POST /farm/<id>/fail` | The print fails now. |
| `POST /farm/<id>/pause`, `/resume` | A runout, and the new roll. |
| `POST /farm/speed?x=120` | The speed of the clock. |
