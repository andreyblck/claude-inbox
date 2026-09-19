import { Action, ActionPanel, Icon, List, Toast, showToast } from "@raycast/api";
import { getProgressIcon, usePromise } from "@raycast/utils";
import { useEffect, useState } from "react";
import {
  accountLabel,
  mergeRows,
  readPending,
  readLiveSessions,
  readRecentActivity,
  readSessions,
  readUsage,
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

const POLL_MS = 1000;

function useInbox() {
  const { data, isLoading, revalidate } = usePromise(async () => {
    const [pending, sessions, live, usage] = await Promise.all([
      readPending(),
      readSessions(),
      readLiveSessions(),
      readUsage(),
    ]);
    return { rows: mergeRows(pending, sessions, live).sort(bySeverity), usage };
  });
  useEffect(() => {
    const timer = setInterval(revalidate, POLL_MS);
    return () => clearInterval(timer);
  }, [revalidate]);
  return { rows: data?.rows ?? [], usage: data?.usage ?? [], isLoading, revalidate };
}

function rowProject(row: Row): string {
  return row.kind === "pending"
    ? projectName(row.pending.cwd, row.pending.session_id)
    : projectName(row.session.cwd, row.session.session_id, row.session.name);
}

function rowAsk(row: Row): string {
  if (row.kind === "pending") return askPhrase(row.pending);
  return row.session.phase ?? STATES[row.state].label.toLowerCase();
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
  const line = (label: string, value?: number, resetsAt?: number) => {
    if (value === undefined || value === null) return `- **${label}** — no data yet`;
    const filled = Math.round(Math.min(100, value) / 10);
    return `- **${label}** \`${"█".repeat(filled)}${"░".repeat(10 - filled)}\` ${pct(value)}${
      resetsIn(resetsAt) ? ` · ${resetsIn(resetsAt)}` : ""
    }`;
  };
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
          {usage.context?.used_percentage !== undefined ? (
            <List.Item.Detail.Metadata.Label title="Context" text={pct(usage.context.used_percentage) ?? "—"} />
          ) : null}
          {usage.cost?.total_cost_usd !== undefined ? (
            <List.Item.Detail.Metadata.Label title="Session cost" text={`$${usage.cost.total_cost_usd.toFixed(2)}`} />
          ) : null}
        </List.Item.Detail.Metadata>
      }
    />
  );
}

export default function Command() {
  const { rows, usage, isLoading, revalidate } = useInbox();
  const [selectedId, setSelectedId] = useState<string | null>(null);

  const { data: activity } = usePromise(
    async (id: string | null) => {
      const row = rows.find((r) => r.id === id);
      return row ? readRecentActivity(rowTranscript(row)) : [];
    },
    [selectedId],
  );

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
            return (
              <List.Item
                key={u.config_dir}
                id={`usage:${u.config_dir}`}
                icon={getProgressIcon((week ?? five ?? 0) / 100, usageTint(week ?? five ?? 0))}
                title={accountLabel(u.config_dir)}
                subtitle={usageLine(u)}
                accessories={[
                  ...(five !== undefined
                    ? [{ icon: getProgressIcon(five / 100, usageTint(five)), tooltip: `5 hours: ${pct(five)}` }]
                    : []),
                  ...(week !== undefined
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
