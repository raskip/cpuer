# Auto-start on boot

Cpuer can be configured to start automatically on login using a macOS LaunchAgent.

## Setup

Create a plist file (replace `/path/to/Cpuer` with the actual path to your built binary):

```bash
cat > ~/Library/LaunchAgents/com.local.cpuer.plist << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.local.cpuer</string>
    <key>ProgramArguments</key>
    <array>
        <string>/path/to/Cpuer</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
EOF
```

Then load it:

```bash
launchctl load ~/Library/LaunchAgents/com.local.cpuer.plist
```

## Disable auto-start (temporarily)

```bash
launchctl unload ~/Library/LaunchAgents/com.local.cpuer.plist
```

This disables it until you load it again or reboot (it will still auto-load on next login since the plist file exists).

## Disable auto-start (permanently)

```bash
launchctl unload ~/Library/LaunchAgents/com.local.cpuer.plist
rm ~/Library/LaunchAgents/com.local.cpuer.plist
```

## Re-enable auto-start

```bash
launchctl load ~/Library/LaunchAgents/com.local.cpuer.plist
```

## Start manually without LaunchAgent

```bash
./Cpuer &
disown
```

## After rebuilding the binary

The LaunchAgent points directly at the binary path you specified, so rebuilding in place (`swiftc ... -o Cpuer`) is enough. The new version runs on next login (or `launchctl unload` + `launchctl load` to restart immediately).

## Troubleshooting

```bash
# Check if the agent is loaded
launchctl list | grep cpuer

# Check for errors
launchctl print gui/$(id -u)/com.local.cpuer
```
