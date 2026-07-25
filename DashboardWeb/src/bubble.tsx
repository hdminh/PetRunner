import { useId, useMemo, useState } from "react";
import { DashboardAPI } from "./api";
import { petAnimationRows, PetSpritePreview } from "./pet-preview";
import type { AppState, MonitorBubbleAppearance, MonitorProviderOption, MonitorSettings, PetInfo } from "./types";

const idleRow = petAnimationRows[0];
const previewPetScale = 0.42;

/** Matches SessionBubbleLayout.baseWidth / bubbleFrame inset. */
const previewBasePanelWidth = 292;
const previewBaseBubbleLeft = 14;
const previewTailExtent = 18;

const bubbleOutline = "#1a1740";
const bubbleFace = "#fcfcff";
const bubbleHighlight = "#d6e3f5";
const bubbleShade = "#9eb3d4";

const previewFields = [
  { id: "model", label: "Model", sample: "OPUS 4.5" },
  { id: "job", label: "Job", sample: "Updating the monitor bubble" },
  { id: "sessionName", label: "Session name", sample: "Agent session" },
  { id: "cost", label: "Cost", sample: "$0.12" },
] as const;

const scaleOptions = [
  { id: "compact", label: "Compact", factor: 0.85 },
  { id: "default", label: "Default", factor: 1 },
  { id: "large", label: "Large", factor: 1.2 },
] as const;

const fontOptions = [
  { id: "sm", label: "Small", model: 11, body: 9 },
  { id: "md", label: "Medium", model: 12, body: 10 },
  { id: "lg", label: "Large", model: 14, body: 12 },
] as const;

type Rect = { x: number; y: number; w: number; h: number };

function headerColorCSS(option?: MonitorProviderOption): string {
  const color = option?.headerColor;
  if (!color) return "#c8ff77";
  const channel = (value: number) => Math.round(Math.min(1, Math.max(0, value)) * 255);
  return `rgb(${channel(color.red)} ${channel(color.green)} ${channel(color.blue)})`;
}

/** Mirrors StackedBubbleBackgroundView.pixelRoundedPath (web y-down). */
function pixelRoundedPath(x: number, y: number, w: number, h: number): string {
  const corner = 6;
  const step = 2;
  const maxX = x + w;
  const maxY = y + h;
  return [
    `M${x + corner} ${y}`,
    `L${maxX - corner} ${y}`,
    `L${maxX - corner} ${y + step}`,
    `L${maxX - step} ${y + step}`,
    `L${maxX - step} ${y + corner}`,
    `L${maxX} ${y + corner}`,
    `L${maxX} ${maxY - corner}`,
    `L${maxX - step} ${maxY - corner}`,
    `L${maxX - step} ${maxY - step}`,
    `L${maxX - corner} ${maxY - step}`,
    `L${maxX - corner} ${maxY}`,
    `L${x + corner} ${maxY}`,
    `L${x + corner} ${maxY - step}`,
    `L${x + step} ${maxY - step}`,
    `L${x + step} ${maxY - corner}`,
    `L${x} ${maxY - corner}`,
    `L${x} ${y + corner}`,
    `L${x + step} ${y + corner}`,
    `L${x + step} ${y + step}`,
    `L${x + corner} ${y + step}`,
    "Z",
  ].join("");
}

function rectPath({ x, y, w, h }: Rect): string {
  return `M${x} ${y}h${w}v${h}h${-w}Z`;
}

function speechBubblePath(body: Rect, tails: Rect[]): string {
  return `${pixelRoundedPath(body.x, body.y, body.w, body.h)}${tails.map(rectPath).join("")}`;
}

/** SessionBubbleLayout.speechTailFrames / speechTailInteriorFrames for side .above (web y-down). */
function speechTailFrames(centerX: number, bottom: number): Rect[] {
  return [
    { x: centerX - 10, y: bottom - 2, w: 20, h: 4 },
    { x: centerX - 10, y: bottom + 2, w: 17, h: 4 },
    { x: centerX - 10, y: bottom + 6, w: 14, h: 4 },
    { x: centerX - 10, y: bottom + 10, w: 11, h: 4 },
    { x: centerX - 10, y: bottom + 14, w: 8, h: 4 },
  ];
}

function speechTailInteriorFrames(centerX: number, bottom: number): Rect[] {
  return [
    { x: centerX - 8, y: bottom - 2, w: 16, h: 10 },
    { x: centerX - 8, y: bottom + 2, w: 13, h: 4 },
    { x: centerX - 8, y: bottom + 6, w: 10, h: 4 },
    { x: centerX - 8, y: bottom + 10, w: 7, h: 4 },
    { x: centerX - 8, y: bottom + 14, w: 4, h: 2 },
  ];
}

function bandSegments(band: Rect, avoid?: Rect): Rect[] {
  if (!avoid) return [band];
  const left = Math.max(band.x, avoid.x);
  const right = Math.min(band.x + band.w, avoid.x + avoid.w);
  const top = Math.max(band.y, avoid.y);
  const bottom = Math.min(band.y + band.h, avoid.y + avoid.h);
  if (left >= right || top >= bottom) return [band];

  const segments: Rect[] = [];
  if (band.x < left) segments.push({ x: band.x, y: band.y, w: left - band.x, h: band.h });
  if (right < band.x + band.w) segments.push({ x: right, y: band.y, w: band.x + band.w - right, h: band.h });
  return segments;
}

function MonitorBubbleChrome({
  width,
  height,
  tailCenterX,
}: {
  width: number;
  height: number;
  /** X within the bubble, matching SessionBubbleLayout.speechTailCenterX. */
  tailCenterX: number;
}) {
  const clipId = useId().replace(/:/g, "");
  const body: Rect = { x: 0, y: 0, w: width, h: height };
  const interior: Rect = { x: 2, y: 2, w: width - 4, h: height - 4 };
  const centerX = Math.min(Math.max(tailCenterX, 10), width - 10);
  const bottom = height;
  const outlineTails = speechTailFrames(centerX, bottom);
  const faceTails = speechTailInteriorFrames(centerX, bottom);
  const join = faceTails[0];
  const mediumBand: Rect = { x: interior.x, y: interior.y + interior.h - 3, w: interior.w, h: 3 };
  const lightBand: Rect = { x: interior.x, y: interior.y + interior.h - 5, w: interior.w, h: 2 };
  const svgHeight = height + previewTailExtent;

  return (
    <svg
      className="monitor-bubble-chrome"
      width={width}
      height={svgHeight}
      viewBox={`0 0 ${width} ${svgHeight}`}
      aria-hidden="true"
    >
      <path d={speechBubblePath(body, outlineTails)} fill={bubbleOutline} />
      <path d={speechBubblePath(interior, faceTails)} fill={bubbleFace} />
      <defs>
        <clipPath id={clipId}>
          <path d={speechBubblePath(interior, faceTails)} />
        </clipPath>
      </defs>
      <g clipPath={`url(#${clipId})`}>
        {bandSegments(mediumBand, join).map((segment) => (
          <rect key={`m-${segment.x}`} x={segment.x} y={segment.y} width={segment.w} height={segment.h} fill={bubbleShade} />
        ))}
        {bandSegments(lightBand, join).map((segment) => (
          <rect key={`l-${segment.x}`} x={segment.x} y={segment.y} width={segment.w} height={segment.h} fill={bubbleHighlight} />
        ))}
        {faceTails.slice(1).map((frame) => {
          const shadeWidth = Math.min(2, frame.w);
          const highlightWidth = Math.min(2, Math.max(frame.w - shadeWidth, 0));
          return (
            <g key={`t-${frame.y}`}>
              <rect x={frame.x + frame.w - shadeWidth} y={frame.y} width={shadeWidth} height={frame.h} fill={bubbleShade} />
              {highlightWidth > 0 ? (
                <rect
                  x={frame.x + frame.w - shadeWidth - highlightWidth}
                  y={frame.y}
                  width={highlightWidth}
                  height={frame.h}
                  fill={bubbleHighlight}
                />
              ) : null}
            </g>
          );
        })}
      </g>
    </svg>
  );
}

/** Bubble customize + preview block for the Monitor page. */
export function MonitorBubbleSection({
  state,
  api,
  onReload,
  onError,
}: {
  state: AppState;
  api: DashboardAPI;
  onReload: () => Promise<void>;
  onError: (message: string) => void;
}) {
  const monitor = state.monitor;
  const options = monitor?.providers ?? [];
  const [busy, setBusy] = useState(false);
  const [resetBusy, setResetBusy] = useState(false);
  const [message, setMessage] = useState<string | null>(null);

  const selected = useMemo(() => {
    const provider = monitor?.provider ?? options[0]?.id ?? null;
    return options.find((entry) => entry.id === provider) ?? options[0];
  }, [options, monitor?.provider]);

  const enabled = Boolean(monitor?.enabled);
  const selectedPetID = state.pet?.selectedID ?? null;
  const selectedPet = useMemo(
    () => (selectedPetID ? state.pets?.find((entry) => entry.id === selectedPetID) ?? null : null),
    [selectedPetID, state.pets],
  );

  const appearance: MonitorBubbleAppearance = monitor?.appearance ?? {
    scale: "default",
    fontSize: "md",
    useProviderHeaderTint: true,
    visibleFields: previewFields.map((field) => field.id),
  };

  const resetBubble = async () => {
    setResetBusy(true);
    setMessage(null);
    try {
      await api.post("monitor/reset");
      setMessage("Session monitor bubble cleared. New agent activity can show it again.");
    } catch (error) {
      onError(error instanceof Error ? error.message : "Could not reset the session monitor.");
    } finally {
      setResetBusy(false);
    }
  };

  const updateAppearance = async (patch: Partial<MonitorBubbleAppearance> & { visibleFields?: string[] }) => {
    setBusy(true);
    setMessage(null);
    try {
      const next = {
        scale: patch.scale ?? appearance.scale,
        fontSize: patch.fontSize ?? appearance.fontSize,
        useProviderHeaderTint: patch.useProviderHeaderTint ?? appearance.useProviderHeaderTint,
        visibleFields: patch.visibleFields ?? appearance.visibleFields,
      };
      await api.put<MonitorSettings>("monitor", next);
      await onReload();
    } catch (error) {
      onError(error instanceof Error ? error.message : "Could not update bubble appearance.");
    } finally {
      setBusy(false);
    }
  };

  const toggleField = (fieldID: string, checked: boolean) => {
    const current = new Set(appearance.visibleFields);
    if (checked) current.add(fieldID);
    else current.delete(fieldID);
    const next = previewFields.map((field) => field.id).filter((id) => current.has(id));
    void updateAppearance({ visibleFields: next.length ? next : ["job"] });
  };

  return (
    <div className="monitor-layout">
      <article className="card monitor-settings-card">
        <div className="section-head">
          <div>
            <p className="kicker">Bubble</p>
            <h2>Customize</h2>
          </div>
        </div>

        <p className="monitor-lede">
          Tune size, text, tint, and which fields appear in the live session bubble.
        </p>

        <p className="kicker">Size</p>
        <div className="width-pills" role="group" aria-label="Bubble scale">
          {scaleOptions.map((option) => (
            <button
              key={option.id}
              type="button"
              className={appearance.scale === option.id ? "active" : ""}
              disabled={busy}
              onClick={() => void updateAppearance({ scale: option.id })}
            >
              {option.label}
            </button>
          ))}
        </div>

        <p className="kicker" style={{ marginTop: "0.85rem" }}>Text</p>
        <div className="width-pills" role="group" aria-label="Bubble font size">
          {fontOptions.map((option) => (
            <button
              key={option.id}
              type="button"
              className={appearance.fontSize === option.id ? "active" : ""}
              disabled={busy}
              onClick={() => void updateAppearance({ fontSize: option.id })}
            >
              {option.label}
            </button>
          ))}
        </div>

        <label className="toggle" style={{ marginTop: "0.85rem" }}>
          <span>Provider header tint</span>
          <input
            type="checkbox"
            checked={appearance.useProviderHeaderTint}
            disabled={busy}
            onChange={(event) => void updateAppearance({ useProviderHeaderTint: event.target.checked })}
            aria-label="Use provider header tint"
          />
          <i aria-hidden="true" />
        </label>

        <ul className="monitor-field-list" aria-label="Visible bubble fields" style={{ marginTop: "0.85rem" }}>
          <li><strong>Provider</strong><span>Always shown</span></li>
          <li><strong>Status</strong><span>Always shown</span></li>
          {previewFields.map((field) => (
            <li key={field.id}>
              <strong>{field.label}</strong>
              <label className="toggle">
                <span>{appearance.visibleFields.includes(field.id) ? "On" : "Off"}</span>
                <input
                  type="checkbox"
                  checked={appearance.visibleFields.includes(field.id)}
                  disabled={busy}
                  onChange={(event) => toggleField(field.id, event.target.checked)}
                  aria-label={`Show ${field.label} in bubble`}
                />
                <i aria-hidden="true" />
              </label>
            </li>
          ))}
        </ul>

        {message ? <p className="form-message" role="status">{message}</p> : null}
        {busy ? <p className="form-message" role="status">Updating…</p> : null}

        <div className="monitor-reset-row">
          <button
            type="button"
            className="secondary"
            onClick={() => void resetBubble()}
            disabled={resetBusy || !enabled}
            title={enabled ? "Clear the live desktop bubble and active session state" : "Enable Agent Monitor to reset the bubble"}
          >
            {resetBusy ? "Resetting…" : "Reset bubble"}
          </button>
          <p>Clears a stuck desktop bubble without disabling hooks.</p>
        </div>
      </article>

      <article className="card monitor-preview-card">
        <div className="section-head">
          <div>
            <p className="kicker">Bubble preview</p>
            <h2>Desktop frame</h2>
          </div>
          <span>Matches live overlay</span>
        </div>
        <MonitorBubblePreview api={api} provider={selected} appearance={appearance} pet={selectedPet} />
      </article>
    </div>
  );
}

function MonitorBubblePreview({
  api,
  provider,
  appearance,
  pet,
}: {
  api: DashboardAPI;
  provider?: MonitorProviderOption;
  appearance: MonitorBubbleAppearance;
  pet: PetInfo | null;
}) {
  const scale = scaleOptions.find((entry) => entry.id === appearance.scale)?.factor ?? 1;
  const font = fontOptions.find((entry) => entry.id === appearance.fontSize) ?? fontOptions[1];
  const visible = new Set(appearance.visibleFields);
  const providerLabel = (provider?.name ?? provider?.id ?? "PROVIDER").toUpperCase();
  const model = visible.has("model") ? previewFields[0].sample : null;
  const job = visible.has("job") ? previewFields[1].sample : "Working…";
  const details = [
    visible.has("sessionName") ? previewFields[2].sample : null,
    visible.has("cost") ? previewFields[3].sample : null,
  ].filter(Boolean) as string[];
  const detailLineCount = (model ? 1 : 0) + 1 + details.length;
  const bubbleHeight = (46 + detailLineCount * 16) * scale;
  const previewPanelWidth = previewBasePanelWidth * scale;
  const previewBubbleLeft = previewBaseBubbleLeft * scale;
  const previewBubbleWidth = previewPanelWidth - previewBubbleLeft;
  const tailCenterX = previewPanelWidth / 2 - previewBubbleLeft;
  const providerColor = appearance.useProviderHeaderTint ? headerColorCSS(provider) : "#1a1740";

  return (
    <div className="monitor-preview-stage" aria-hidden="true">
      <div className="monitor-preview-scene" style={{ width: previewPanelWidth }}>
        <div
          className="monitor-bubble"
          style={{
            width: previewBubbleWidth,
            marginLeft: previewBubbleLeft,
            height: bubbleHeight + previewTailExtent * scale,
          }}
        >
          <MonitorBubbleChrome
            width={previewBubbleWidth}
            height={bubbleHeight}
            tailCenterX={tailCenterX}
          />
          <div className="monitor-bubble-face" style={{ height: bubbleHeight }}>
            <div className="monitor-bubble-toolbar">
              <span className="monitor-bubble-minimize" title="Minimize" />
              <span className="monitor-bubble-reset" title="Reset" />
              <span className="monitor-bubble-provider" style={{ color: providerColor }}>{providerLabel}</span>
              <span className="monitor-bubble-nav" aria-hidden="true">
                <i className="monitor-bubble-nav-btn is-up is-disabled" />
                <i className="monitor-bubble-nav-btn is-down is-disabled" />
              </span>
              <span className="monitor-bubble-position">1/1</span>
            </div>
            <span className="monitor-bubble-indicator is-working" title="Working" />
            <div className="monitor-bubble-body" style={{ fontSize: `${font.body}px` }}>
              {model ? <strong className="monitor-bubble-model" style={{ fontSize: `${font.model}px` }}>{model}</strong> : null}
              <p className="monitor-bubble-job">{job}</p>
              {details.map((line) => (
                <span key={line} className="monitor-bubble-detail">{line}</span>
              ))}
            </div>
          </div>
        </div>

        {pet ? (
          <PetSpritePreview
            api={api}
            pet={pet}
            row={idleRow}
            scale={previewPetScale}
            className="monitor-preview-pet"
            label={`${pet.name} desktop pet`}
          />
        ) : (
          <div className="monitor-preview-pet monitor-preview-pet-empty" />
        )}
      </div>
    </div>
  );
}
