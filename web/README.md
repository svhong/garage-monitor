# `<GarageMonitor />` for your website

A drop-in React component (React 16.8 or newer, no other dependencies) that
shows the live dashboard behind a password screen.

## How it stays private

1. **Password checked by the hub.** The component only shows a login form.
   The hub on hermes-box checks the password and returns a session. Your
   website's code holds no password or secret, so viewing its source reveals nothing.
2. **The hub is only on your Tailscale.** Visitors who aren't on your tailnet
   can't reach it at all. They just see the lock screen.
3. **Only your website is allowed.** The hub only answers browsers on the
   site address(es) you list with `--allow-origin`.

## Setup

### 1. On hermes-box: turn on HTTPS, set a password, allow your site

Your website is served over `https://`, and browsers block an https page from
loading data from a plain `http://` address. Tailscale can give the hub a
free HTTPS address.

1. In the Tailscale admin console → **DNS**, make sure **MagicDNS** and
   **HTTPS Certificates** are turned on.
2. On hermes-box, in the cloned repo (run `git pull` first if you cloned it earlier):

   ```bash
   sudo ./install.sh --https --set-password --allow-origin https://YOUR-SITE.com
   ```

   For testing from your laptop's dev server, add a second
   `--allow-origin http://localhost:5173`.
3. Note the `https://hermes-box.<your-tailnet>.ts.net` address it prints.

### 2. In your site's repo

Copy `GarageMonitor.jsx` and `GarageMonitor.css` into your project, e.g.
`src/components/`, then use the component on any page:

```jsx
import GarageMonitor from "./components/GarageMonitor";

export default function MonitorPage() {
  return <GarageMonitor hubUrl="https://hermes-box.your-tailnet.ts.net" />;
}
```

Props:

| Prop | Default | What it does |
|---|---|---|
| `hubUrl` | required | The hub's HTTPS address from step 1 |
| `title` | `"Garage Monitor"` | Heading text |
| `pollMs` | `2000` | Refresh interval in milliseconds |
| `theme` | `"auto"` | `"auto"` follows the device; or `"dark"` / `"light"` |

To change the colors, edit the variables at the top of `GarageMonitor.css`.

## Good to know

- **Chrome may ask once** whether your site can "access devices on your local
  network". That's because Tailscale addresses count as private. Click Allow.
- **"Remember this device"** keeps you logged in for 7 days on that browser.
  Without it, the login lasts until you close the tab. **Lock** logs out
  immediately. Restarting the hub logs everyone out.
- After **5 wrong passwords**, the hub ignores login attempts for a minute.
- To change the password: `sudo ./install.sh --set-password`.
- The component pauses refreshing while the tab is in the background,
  to save phone battery.
