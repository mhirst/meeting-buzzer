# MeetingBuzzer

A lightweight macOS menu bar app that watches your calendar and throws up a full-screen overlay when a meeting is about to start — so you never silently miss one.

## What it does

- Sits in the menu bar and polls your calendar every 10 seconds
- Shows a full-screen overlay on **all connected displays** 60 seconds before a meeting starts
- Detects video conference links (Zoom, Google Meet, Teams, Webex, etc.) and surfaces a **Join Meeting** button directly on the overlay
- Catches meetings you might have missed while your Mac was asleep — re-checks immediately on wake/unlock
- Displays the next upcoming meeting in the menu bar (with urgency indicators as the start time approaches)
- Lets you toggle individual calendars on/off from the menu; events you're invited to always alert regardless of calendar settings
- Auto-dismisses the overlay after 45 seconds if you don't interact with it

## Requirements

- macOS 13 Ventura or later (macOS 14 Sonoma recommended for full calendar access API)
- Calendar access permission (prompted on first launch)

## Installation

### Option 1 — Build from source (Xcode)

1. Clone the repo: `git clone https://github.com/mhirst/meeting-buzzer.git`
2. Open the `MeetingBuzzer` folder in Xcode (double-click `MeetingBuzzer.xcodeproj`, or `xed MeetingBuzzer` from the terminal)
3. Select your Mac as the run destination in the toolbar
4. Press **⌘R** to build and run

To keep it running after you close Xcode, go to **Product → Archive**, then export the app and move it to `/Applications`.

### Option 2 — Run automatically at login

Once the app is in `/Applications`:

1. Open **System Settings → General → Login Items**
2. Click **+** under "Open at Login" and select `MeetingBuzzer.app`

The bell icon will appear in your menu bar on every login.

## Permissions

On first launch, macOS will ask for Calendar access. Grant **Full Access** so the app can read event details including notes and location (where video links are often embedded).

## Menu bar

| Item | Description |
|---|---|
| Next Meeting | Shows the upcoming event and time until it starts |
| Test Alert | Fires the overlay immediately for the next event (or a dummy if none found) |
| Open Log | Opens the log file at `~/Library/Logs/MeetingBuzzer.log` |
| Calendars | Toggle which calendars trigger alerts |
| Quit | Exits the app |

## Supported video conferencing

Zoom, Google Meet, Microsoft Teams, Webex, GoToMeeting, Amazon Chime, Whereby, Around
