import { Action, ActionPanel, Icon, List, Toast, showToast } from "@raycast/api";
import { getProgressIcon, usePromise } from "@raycast/utils";
import { useEffect, useMemo, useState } from "react";
import {
  accountLabel,
  mergeRows,
  readPending,
  readLiveSessions,
  readRecentActivity,
  readSessions,
  readUsage,
  touchHeartbeat,
  writeVerdict,
  type Row,
  type UsageRecord,
} from "./lib/inbox";
import { activityLine, codeBlock, pct, resetsIn, usageLine, usageTint } from "./lib/format";
import {
  age,
  askDetail,
  askPhrase,
  bySeverity,
  GROUP_TITLES,
  projectName,
  rowTitle,
  STATES,
  type StateGroup,
} from "./lib/state";

/** Rows are cheap local file reads; the transcript tail is not. */
const ROWS_POLL_MS = 1000;
const ACTIVITY_POLL_MS = 4000;

function useInterval(revalidate: () => void, ms: number) {
  useEffect(() => {
    const timer = setInterval(revalidate, ms);
    return () => clearInterval(timer);
  }, [revalidate, ms]);
}

function useInbox() {
  const { data, isLoading, revalidate } = usePromise(async () => {
    await touchHeartbeat("inbox");
    const [pending, sessions, live, usage] = await Promise.all([
      readPending(),
      readSessions(),
      readLiveSessions(),
      readUsage(),
    ]);
    return { rows: mergeRows(pending, sessions, live).sort(bySeverity), usage };
  });
  useInterval(revalidate, ROWS_POLL_MS);
  return {
    rows: data?.rows ?? [],
    usage: data?.usage ?? [],
    // `usePromise` flips isLoading on every revalidate, so binding it straight to
    // the List makes the loading bar pulse once a second forever. Only the first
    // load has nothing to show.
    isLoading: isLoading && !data,
    revalidate,
  };
}

function rowProject(row: Row): string {
  return row.kind === "pending"
    ? projectName(row.pending.cwd, row.pending.session_id)
    : projectName(row.session.cwd, row.session.session_id, row.session.name);
}

function rowAsk(row: Row): string {
  if (row.kind === "pending") return askPhrase(row.pending);
  // A dialog the terminal owns says what it wants; that beats the state name.
  return row.session.waiting_for ?? row.session.phase ?? STATES[row.state].label.toLowerCase();
}

function rowTranscript(row: Row): string | undefined {
  return row.kind === "pending" ? row.pending.transcript_path : row.session.transcript_path;
}

function Detail({ row, activity }: { row: Row; activity: string[] }) {
  const meta = STATES[row.state];
  const command = row.kind === "pending" ? askDetail(row.pending) : undefined;
  const cwd = row.kind === "pending" ? row.pending.cwd : row.session.cwd;
  const mode = row.kind === "pending" ? row.pending.permission_mode : row.session.permission_mode;
  const lastMessage = row.kind === "session" ? row.session.last_message : undefined;

  const markdown = [
    `## ${rowAsk(row)}`,
    "",
    codeBlock(command),
    lastMessage ? `${lastMessage.slice(0, 600)}\n` : "",
    activityLine(activity),
  ]
    .filter(Boolean)
    .join("\n");

  return (
    <List.Item.Detail
      markdown={markdown}
      metadata={
        <List.Item.Detail.Metadata>
          <List.Item.Detail.Metadata.TagList title="State">
            <List.Item.Detail.Metadata.TagList.Item text={meta.label} color={meta.tint} />
          </List.Item.Detail.Metadata.TagList>
          <List.Item.Detail.Metadata.Label title="Project" text={rowProject(row)} />
          {cwd ? <List.Item.Detail.Metadata.Label title="Path" text={cwd} /> : null}
          {row.kind === "pending" && row.pending.tool_name ? (
            <List.Item.Detail.Metadata.Label title="Tool" text={row.pending.tool_name} />
          ) : null}
          {mode ? <List.Item.Detail.Metadata.Label title="Mode" text={mode} /> : null}
          <List.Item.Detail.Metadata.Separator />
          <List.Item.Detail.Metadata.Label title="Since" text={age(row.ts)} />
        </List.Item.Detail.Metadata>
      }
    />
  );
}

function UsageDetail({ usage }: { usage: UsageRecord }) {
  const five = usage.rate_limits?.five_hour;
  const week = usage.rate_limits?.seven_day;
  const line = (label: string, value?: number | null, resetsAt?: number | null) => {
    if (value === undefined || value === null) return `- **${label}** — no data yet`;
    const filled = Math.round(Math.min(100, value) / 10);
    const reset = resetsIn(resetsAt ?? undefined);
    return `- **${label}** \`${"█".repeat(filled)}${"░".repeat(10 - filled)}\` ${pct(value)}${reset ? ` · ${reset}` : ""}`;
  };
  const context = usage.context?.used_percentage;
  const cost = usage.cost?.total_cost_usd;
  return (
    <List.Item.Detail
      markdown={[
        `## ${accountLabel(usage.config_dir)}`,
        "",
        line("5 hours", five?.used_percentage, five?.resets_at),
        line("7 days", week?.used_percentage, week?.resets_at),
        "",
        `Reported ${age(usage.ts)} by the last session that spoke. It only moves while Claude is answering.`,
      ].join("\n")}
      metadata={
        <List.Item.Detail.Metadata>
          <List.Item.Detail.Metadata.Label title="Account" text={accountLabel(usage.config_dir)} />
          <List.Item.Detail.Metadata.Label title="Config" text={usage.config_dir} />
          {usage.model ? <List.Item.Detail.Metadata.Label title="Model" text={usage.model} /> : null}
          {/* A reading of `null` is "not measured yet", which is not a row worth
              printing — and `!== undefined` lets it through as an em dash. */}
          {typeof context === "number" ? (
            <List.Item.Detail.Metadata.Label title="Context" text={pct(context) ?? "—"} />
          ) : null}
          {typeof cost === "number" ? (
            <List.Item.Detail.Metadata.Label title="Session cost" text={`$${cost.toFixed(2)}`} />
          ) : null}
        </List.Item.Detail.Metadata>
      }
    />
  );
}

export default function Command() {
  const { rows, usage, isLoading, revalidate } = useInbox();
  const [selectedId, setSelectedId] = useState<string | null>(null);

  // Keyed by the transcript path, not by the row id: the path is what the read
  // actually depends on, so this refires when rows first arrive (the selection
  // lands before the first read resolves) and not on every unrelated poll.
  const selectedTranscript = useMemo(() => {
    const row = rows.find((r) => r.id === selectedId);
    return row ? rowTranscript(row) : undefined;
  }, [rows, selectedId]);

  const { data: activity, revalidate: revalidateActivity } = usePromise(
    async (path?: string) => readRecentActivity(path),
    [selectedTranscript],
  );
  useInterval(revalidateActivity, ACTIVITY_POLL_MS);

  async function decide(row: Row, decision: "allow" | "deny") {
    if (row.kind !== "pending") return;
    await writeVerdict(row.pending.req, decision, `${decision === "allow" ? "Approved" : "Denied"} in Raycast`);
    await showToast({
      style: decision === "allow" ? Toast.Style.Success : Toast.Style.Failure,
      title: decision === "allow" ? "Approved" : "Denied",
      message: rowTitle(rowProject(row), rowAsk(row)),
    });
    revalidate();
  }

  const groups: StateGroup[] = ["waiting", "running", "finished"];

  return (
    <List
      isLoading={isLoading}
      isShowingDetail
      searchBarPlaceholder="Filter sessions"
      // Rows are rebuilt every second and reorder as states change, which moves
      // an item between sections. Naming the selection keeps it on the row the
      // person was reading instead of snapping back to the top.
      selectedItemId={selectedId ?? undefined}
      onSelectionChange={setSelectedId}
    >
      <List.EmptyView
        icon={Icon.CheckCircle}
        title="Nothing needs you"
        description="Sessions appear here the moment one blocks on a decision."
      />

      {groups.map((group) => {
        const items = rows.filter((row) => STATES[row.state].group === group);
        if (!items.length) return null;
        return (
          <List.Section key={group} title={GROUP_TITLES[group]} subtitle={String(items.length)}>
            {items.map((row) => {
              const meta = STATES[row.state];
              const command = row.kind === "pending" ? askDetail(row.pending) : undefined;
              return (
                <List.Item
                  key={row.id}
                  id={row.id}
                  icon={{ source: meta.icon, tintColor: meta.tint }}
                  title={rowTitle(rowProject(row), rowAsk(row))}
                  accessories={[{ tag: { value: meta.label, color: meta.tint } }, { text: age(row.ts) }]}
                  detail={<Detail row={row} activity={selectedId === row.id ? (activity ?? []) : []} />}
                  actions={
                    <ActionPanel>
                      {row.kind === "pending" ? (
                        <>
                          {/* Approve is the primary action, so Raycast binds ↵ to it
                              automatically. ⌘↵ and ⌘⌫ are reserved by Raycast and get
                              stripped silently, which is why Deny needs its own. */}
                          <Action title="Approve" icon={Icon.Check} onAction={() => decide(row, "allow")} />
                          <Action
                            title="Deny"
                            icon={Icon.XMarkCircle}
                            style={Action.Style.Destructive}
                            shortcut={{ modifiers: ["cmd", "shift"], key: "d" }}
                            onAction={() => decide(row, "deny")}
                          />
                        </>
                      ) : null}
                      {command ? <Action.CopyToClipboard title="Copy Command" content={command} /> : null}
                      {rowTranscript(row) ? (
                        <Action.ShowInFinder title="Reveal Transcript" path={rowTranscript(row) as string} />
                      ) : null}
                      <Action
                        title="Refresh"
                        icon={Icon.ArrowClockwise}
                        shortcut={{ modifiers: ["cmd"], key: "r" }}
                        onAction={revalidate}
                      />
                    </ActionPanel>
                  }
                />
              );
            })}
          </List.Section>
        );
      })}

      {usage.length ? (
        <List.Section title="Usage">
          {usage.map((u) => {
            const five = u.rate_limits?.five_hour?.used_percentage;
            const week = u.rate_limits?.seven_day?.used_percentage;
            const peak = week ?? five ?? 0;
            return (
              <List.Item
                key={u.config_dir}
                id={`usage:${u.config_dir}`}
                icon={getProgressIcon(peak / 100, usageTint(peak))}
                title={accountLabel(u.config_dir)}
                subtitle={usageLine(u)}
                accessories={[
                  ...(typeof five === "number"
                    ? [{ icon: getProgressIcon(five / 100, usageTint(five)), tooltip: `5 hours: ${pct(five)}` }]
                    : []),
                  ...(typeof week === "number"
                    ? [{ icon: getProgressIcon(week / 100, usageTint(week)), tooltip: `7 days: ${pct(week)}` }]
                    : []),
                ]}
                detail={<UsageDetail usage={u} />}
                actions={
                  <ActionPanel>
                    <Action
                      title="Refresh"
                      icon={Icon.ArrowClockwise}
                      shortcut={{ modifiers: ["cmd"], key: "r" }}
                      onAction={revalidate}
                    />
                  </ActionPanel>
                }
              />
            );
          })}
        </List.Section>
      ) : null}
    </List>
  );
}
