# YouLess (local): SmartThings Edge driver

Reads a **YouLess LS110 / LS120** energy monitor directly over the LAN, on the SmartThings hub itself. No cloud, no bridge, no account: the YouLess has a small web server without login.

| Reading | Where |
|---|---|
| Power now (W; negative while solar panels return power to the grid) | main |
| Energy used (kWh) | main |
| Energy returned to the grid (kWh) | component "Returned to grid" |
| Gas (m³) | component "Gas" |

With a **P1 smart meter** (LS120) you get all four (`/e`). With the **optical sensor** on an old meter (LS110, LS120 without P1) you get power and the meter count (`/a`).

## Install

1. Give the YouLess a fixed IP in your router (DHCP reservation).
2. Install the driver from the channel **Stoeckie Edge Drivers** and pick your hub.
3. The device "YouLess" is added automatically: about 20 seconds after the driver starts without any device, it searches the hub's network (/24) for a YouLess and creates the device when it finds one. **Scan nearby** in the SmartThings app works too.
4. Not found (other subnet)? Open the device settings and set **YouLess IP address**.

## Settings

* **YouLess IP address**: `auto` (search) or a fixed IP.
* **Read every (seconds)**: 5 to 300, default 10.
* **Offline after (minutes)**: the connection only turns Offline after this time without contact.

SmartThings takes about one event a minute per device, so power goes out at most once a minute (every 15 s for a jump of 500 W or more), the totals every 5 minutes. Refresh sends the current values right away.

The device also has **Connection** (online / offline) and **Last drop**, usable in routines to notify when the YouLess stops answering.

## Privacy

The YouLess does not need internet for this driver: you can block its internet access in your router. Only its own firmware updates and the YouLess cloud upload use the internet.

## Development

`python -m pytest tests` (needs `pip install lupa pytest`): model tests and a smoke test of the driver with a mocked SmartThings runtime and a mocked YouLess.

## License

Apache 2.0, see LICENSE and NOTICE.
