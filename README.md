> [!WARNING]
> This is Frontier Health’s MDM-only fork of [Maccy](https://github.com/p0deje/Maccy). Obtain staff packages through your organisation’s MDM. See [build identity](docs/build-identity.md) before packaging.

<img width="128px" src="https://maccy.app/img/maccy/Logo.png" alt="Logo" />

# [Maccy](https://github.com/Frontier-Health/Maccy)


Maccy is a lightweight clipboard manager for macOS. It keeps the history of what you copy
and lets you quickly navigate, search, and use previous clipboard contents.

Maccy works on macOS Sonoma 14 or higher.

<!-- vim-markdown-toc GFM -->

* [Features](#features)
* [Install](#install)
* [Usage](#usage)
* [Advanced](#advanced)
  * [Ignore Copied Items](#ignore-copied-items)
  * [Ignore Copies from Applications](#ignore-copies-from-applications)
  * [Ignore Custom Copy Types](#ignore-custom-copy-types)
  * [Speed up Clipboard Check Interval](#speed-up-clipboard-check-interval)
* [FAQ](#faq)
  * [Why doesn't it paste when I select an item in history?](#why-doesnt-it-paste-when-i-select-an-item-in-history)
  * [When assigning a hotkey to open Maccy, it says that this hotkey is already used in some system setting.](#when-assigning-a-hotkey-to-open-maccy-it-says-that-this-hotkey-is-already-used-in-some-system-setting)
  * [How to restore hidden footer?](#how-to-restore-hidden-footer)
  * [How to ignore copies from Universal Clipboard?](#how-to-ignore-copies-from-universal-clipboard)
  * [My keyboard shortcut stopped working in password fields. How do I fix this?](#my-keyboard-shortcut-stopped-working-in-password-fields-how-do-i-fix-this)
* [Translations](#translations)
* [Motivation](#motivation)
* [License](#license)

<!-- vim-markdown-toc -->

## Features

* Lightweight and fast
* Keyboard-first
* Secure and private
* Native UI
* Open source and free

## Install

This fork is distributed to staff Macs only through MDM as a signed, notarized package.
Updates are delivered by MDM; the app has no self-updater.

## Usage

1. <kbd>SHIFT (⇧)</kbd> + <kbd>COMMAND (⌘)</kbd> + <kbd>C</kbd> to popup Maccy or click on its icon in the menu bar.
2. Type what you want to find.
3. To select the history item you wish to copy, press <kbd>ENTER</kbd>, or click the item, or use <kbd>COMMAND (⌘)</kbd> + `n` shortcut.
4. To choose the history item and paste, press <kbd>OPTION (⌥)</kbd> + <kbd>ENTER</kbd>, or <kbd>OPTION (⌥)</kbd> + <kbd>CLICK</kbd> the item, or use <kbd>OPTION (⌥)</kbd> + `n` shortcut.
5. To choose the history item and paste without formatting, press <kbd>OPTION (⌥)</kbd> + <kbd>SHIFT (⇧)</kbd> + <kbd>ENTER</kbd>, or <kbd>OPTION (⌥)</kbd> + <kbd>SHIFT (⇧)</kbd> + <kbd>CLICK</kbd> the item, or use <kbd>OPTION (⌥)</kbd> + <kbd>SHIFT (⇧)</kbd> + `n` shortcut.
6. To delete the history item, press <kbd>OPTION (⌥)</kbd> + <kbd>DELETE (⌫)</kbd>.
7. To see the full text of the history item, wait a couple of seconds for tooltip.
8. To pin the history item so that it remains on top of the list, press <kbd>OPTION (⌥)</kbd> + <kbd>P</kbd>. The item will be moved to the top with a random but permanent keyboard shortcut. To unpin it, press <kbd>OPTION (⌥)</kbd> + <kbd>P</kbd> again.
9. To clear all unpinned items, select _Clear_ in the menu, or press <kbd>OPTION (⌥)</kbd> + <kbd>COMMAND (⌘)</kbd> + <kbd>DELETE (⌫)</kbd>. To clear all items including pinned, select _Clear_ in the menu with  <kbd>OPTION (⌥)</kbd> pressed, or press <kbd>SHIFT (⇧)</kbd> + <kbd>OPTION (⌥)</kbd> + <kbd>COMMAND (⌘)</kbd> + <kbd>DELETE (⌫)</kbd>.
10. To disable Maccy and ignore new copies, click on the menu icon with <kbd>OPTION (⌥)</kbd> pressed.
11. To ignore only the next copy, click on the menu icon with <kbd>OPTION (⌥)</kbd> + <kbd>SHIFT (⇧)</kbd> pressed.
12. To customize the behavior, check "Preferences…" window, or press <kbd>COMMAND (⌘)</kbd> + <kbd>,</kbd>.

## Advanced

### Ignore Copied Items

You can tell Maccy to ignore all copied items:

```sh
defaults write <ORG_BUNDLE_ID> captureMode paused # default is capturing
```

A script can set `captureMode` to `paused`, copy the data and set `captureMode` back to `capturing`. Treat this as best-effort, not as a guarantee: Maccy learns about a `defaults write` from another process after a short, unspecified delay, so a script that pauses, copies and resumes in quick succession can still have its copy recorded. To be sure a copy is not recorded, pause from the menu icon or the settings toggle (those take effect immediately), or leave Maccy paused.

To ignore only the next copy, set `captureMode` to `skipNext`. Maccy switches back to `capturing` after skipping one copy that it would otherwise have recorded. Copies it ignores anyway (empty, concealed or transient, from ignored apps, of ignored types or matching ignore patterns) and Maccy's own copies don't use up the skip.

Any value of `captureMode` other than exactly `capturing`, `paused` or `skipNext` is treated as `paused`. When Maccy notices that a capture setting changed since its last check, it discards the copy it finds rather than guess whether it came before or after the change.

The older `ignoreEvents` and `ignoreOnlyNextEvent` keys still work, but only to make Maccy capture less: `ignoreEvents` set to true pauses Maccy until it is set back to false or removed, and `ignoreOnlyNextEvent` set to true skips the next copy and is then removed. Use `captureMode` in new scripts.

You can also click the menu icon with <kbd>OPTION (⌥)</kbd> pressed. To ignore only the next copy, click with <kbd>OPTION (⌥)</kbd> + <kbd>SHIFT (⇧)</kbd> pressed.

If a configuration profile manages `captureMode`, or sets `ignoreEvents` or `ignoreOnlyNextEvent` to true, the settings toggle and the menu icon clicks can't change whether Maccy captures. A managed `captureMode` of `skipNext` is treated as `paused`. While `captureMode` is managed, an `ignoreOnlyNextEvent` set to true also pauses Maccy, and the old keys are not removed for you: delete them with `defaults delete` to resume.

### Ignore Copies from Applications

In Settings › Ignore you can list applications whose copies Maccy ignores, or turn on "Ignore all applications except listed" so that only the listed ones are recorded. With that option on, a copy is not recorded when Maccy can't tell which application it came from (no frontmost application, or one without a bundle identifier).

This is best-effort, not a guarantee. Maccy identifies the source as the application in front when it notices the copy, which happens up to one check interval (0.5 seconds by default) after the copy. That can be the wrong application for background apps, scripts, and copies made just before switching apps. Do not rely on it alone to keep secrets out of the history. Use the ignore patterns in Settings › Ignore and pause capture (see above) as well.

Maccy does not use the `org.nspasteboard.source` pasteboard type to find the source application. It writes that type on its own copies (copying from history, and the search query or OCR text copied from Maccy) and reads it only to recognise those. It is not stored from copies made by other applications.

### Ignore Custom Copy Types

By default Maccy will ignore certain copy types that are considered to be confidential
or temporary. The default list always include the following types:

* `org.nspasteboard.TransientType`
* `org.nspasteboard.ConcealedType`
* `org.nspasteboard.AutoGeneratedType`

Also, default configuration includes the following types but they can be removed
or overwritten:

* `com.agilebits.onepassword`
* `com.typeit4me.clipping`
* `de.petermaurer.TransientPasteboardType`
* `Pasteboard generator type`
* `net.antelle.keeweb`

You can add additional custom types using settings.
To find what custom types are used by an application, you can use
free application [Pasteboard-Viewer](https://github.com/sindresorhus/Pasteboard-Viewer).
Simply download the application, open it, copy something from the application you
want to ignore and look for any custom types in the left sidebar. [Here is an example
of using this approach to ignore Adobe InDesign](https://github.com/p0deje/Maccy/issues/125).

### Speed up Clipboard Check Interval

By default, Maccy checks clipboard every 500 ms, which should be enough for most users. If you want
to speed it up, you can change it with `defaults`:

```sh
defaults write <ORG_BUNDLE_ID> clipboardCheckInterval 0.1 # 100 ms
```

## FAQ

### Why doesn't it paste when I select an item in history?

1. Make sure you have "Paste automatically" enabled in Preferences.
2. Make sure "Maccy" is added to System Settings -> Privacy & Security -> Accessibility.

### When assigning a hotkey to open Maccy, it says that this hotkey is already used in some system setting.

1. Open System settings -> Keyboard -> Keyboard Shortcuts.
2. Find where that hotkey is used. For example, "Convert text to simplified Chinese" is under Services -> Text.
3. Disable that hotkey or remove assigned combination ([screenshot](https://github.com/p0deje/Maccy/assets/576152/446719e6-c3e5-4eb0-95fb-5a811066487f)).
4. Restart Maccy.
5. Assign hotkey in Maccy settings.

### How to restore hidden footer?

1. Open Maccy window.
2. Press <kbd>COMMAND (⌘)</kbd> + <kbd>,</kbd> to open preferences.
3. Enable footer in Appearance section.

If for some reason it doesn't work, run the following command in Terminal.app:

```sh
defaults write <ORG_BUNDLE_ID> showFooter 1
```

### How to ignore copies from [Universal Clipboard](https://support.apple.com/en-us/102430)?

1. Open Preferences -> Ignore -> Pasteboard Types.
2. Add `com.apple.is-remote-clipboard`.

### My keyboard shortcut stopped working in password fields. How do I fix this?

If your shortcut produces a character (like `Option+C` → "ç"), macOS security may block it in password fields. Use [Karabiner-Elements](https://karabiner-elements.pqrs.org/) to remap your shortcut to a different combination like `Cmd+Shift+C`. [See detailed solution](docs/keyboard-shortcut-password-fields.md).

## Translations

The translations are hosted in [Weblate](https://hosted.weblate.org/engage/maccy/).
You can use it to suggest changes in translations and localize the application to a new language.

[![Translation status](https://hosted.weblate.org/widget/maccy/multi-auto.svg)](https://hosted.weblate.org/engage/maccy/)

## Motivation

There are dozens of similar applications out there, so why build another?
Over the past years since I moved from Linux to macOS, I struggled to find
a clipboard manager that is as free and simple as [Parcellite](http://parcellite.sourceforge.net),
but I couldn't. So I've decided to build one.

Also, I wanted to learn Swift and get acquainted with macOS application development.

## License

[MIT](./LICENSE)
