/// <reference types="@raycast/api">

/* 🚧 🚧 🚧
 * This file is auto-generated from the extension's manifest.
 * Do not modify manually. Instead, update the `package.json` file.
 * 🚧 🚧 🚧 */

/* eslint-disable @typescript-eslint/ban-types */

type ExtensionPreferences = {
  /** Inbox directory - Where the bridge hooks write state. Leave empty for ~/.claude/inbox. */
  "inboxDir": string
}

/** Preferences accessible in all the extension's commands */
declare type Preferences = ExtensionPreferences

declare namespace Preferences {
  /** Preferences accessible in the `inbox` command */
  export type Inbox = ExtensionPreferences & {}
  /** Preferences accessible in the `menubar` command */
  export type Menubar = ExtensionPreferences & {}
}

declare namespace Arguments {
  /** Arguments passed to the `inbox` command */
  export type Inbox = {}
  /** Arguments passed to the `menubar` command */
  export type Menubar = {}
}

