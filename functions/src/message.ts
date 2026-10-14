import type { TokenMessage } from "firebase-admin/messaging";

import type { TicketPlatform } from "./ticket";

/** Coarse event kinds; the only event detail visible outside the device. */
export const pushKinds = [
  "permission",
  "input",
  "finished",
  "alert",
  "test",
] as const;

/** A coarse event kind. */
export type PushKind = (typeof pushKinds)[number];

/** Kinds that wait on the user; they get their own rate-limit budget. */
export function isUrgentKind(kind: PushKind): boolean {
  return kind === "permission" || kind === "input";
}

/**
 * Rate-limit budget for a kind. Tests have their own, so "Send test" can
 * never hold back an approval request.
 */
export function budgetFor(kind: PushKind): "urgent" | "routine" | "test" {
  if (kind === "test") return "test";
  return isUrgentKind(kind) ? "urgent" : "routine";
}

/** Whether [value] is a known kind. */
export function isPushKind(value: unknown): value is PushKind {
  return (
    typeof value === "string" && (pushKinds as readonly string[]).includes(value)
  );
}

interface KindPresentation {
  readonly title: string;
  readonly body: string;
  readonly urgent: boolean;
}

const presentations: Record<PushKind, KindPresentation> = {
  permission: {
    title: "Approval needed",
    body: "An agent is waiting for your approval.",
    urgent: true,
  },
  input: {
    title: "Input needed",
    body: "An agent is waiting for your answer.",
    urgent: true,
  },
  finished: {
    title: "Agent finished",
    body: "An agent finished its turn.",
    urgent: false,
  },
  alert: {
    title: "Terminal alert",
    body: "A terminal window wants your attention.",
    urgent: false,
  },
  test: {
    title: "MonkeySSH",
    body: "Push notifications are working.",
    urgent: true,
  },
};

/** Android channel the app creates for events that wait on the user. */
export const androidChannelId = "agent-attention";
/**
 * Android channel for routine events (finished turns, window alerts): default
 * importance, so they sound and show in the status bar without popping up. On
 * Android 8+ the channel, not the message priority, decides sound and heads-up
 * display. It replaced the low-importance "agent-updates", whose finished
 * turns sat collapsed in the Silent section; an app without this channel
 * shows the message on the manifest's default, "agent-attention".
 */
export const androidRoutineChannelId = "agent-updates-v2";
const androidIcon = "ic_notification_monkey";
const timeToLiveSeconds = 3600;

/** Inputs for [buildFcmMessage]. */
export interface FcmMessageInput {
  readonly token: string;
  readonly kind: PushKind;
  readonly collapse: string;
  readonly payload: string;
  readonly platform?: TicketPlatform;
  readonly nowSeconds: number;
}

/**
 * Builds the FCM message. Visible text comes from the coarse kind only; the
 * encrypted payload travels as data for the app to open.
 *
 * Android gets a data-only message: the app decrypts the payload and posts the
 * notification itself, naming the host and agent, on the channel for the
 * kind. `k` (the kind) and `c` (the collapse key) let it post a generic one
 * when the payload does not open. Every such push must end in a visible
 * notification, so it is sent at high priority to wake the app. iOS (and a
 * ticket without a platform) gets an alert the notification service extension
 * rewrites.
 */
export function buildFcmMessage(input: FcmMessageInput): TokenMessage {
  const presentation = presentations[input.kind];
  if (input.platform === "android") {
    return {
      token: input.token,
      data: { v: "1", p: input.payload, k: input.kind, c: input.collapse },
      android: {
        priority: "high",
        collapseKey: input.collapse,
        ttl: timeToLiveSeconds * 1000,
      },
    };
  }
  return {
    token: input.token,
    notification: { title: presentation.title, body: presentation.body },
    data: { v: "1", p: input.payload },
    android: {
      priority: presentation.urgent ? "high" : "normal",
      collapseKey: input.collapse,
      ttl: timeToLiveSeconds * 1000,
      notification: {
        channelId: presentation.urgent ? androidChannelId : androidRoutineChannelId,
        tag: input.collapse,
        icon: androidIcon,
      },
    },
    apns: {
      headers: {
        "apns-priority": presentation.urgent ? "10" : "5",
        "apns-push-type": "alert",
        "apns-collapse-id": input.collapse,
        "apns-expiration": String(input.nowSeconds + timeToLiveSeconds),
      },
      payload: {
        aps: {
          mutableContent: true,
          threadId: "monkeyssh-agents",
          ...(presentation.urgent ? { sound: "default" } : {}),
        },
      },
    },
  };
}
