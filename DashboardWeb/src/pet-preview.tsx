import { useEffect, useState, type CSSProperties } from "react";
import { DashboardAPI } from "./api";
import type { PetInfo } from "./types";

export const PET_CELL = 192;
export const PET_CELL_H = 208;

export type PetAnimationRow = {
  id: string;
  label: string;
  row: number;
  frames: number;
  action?: string;
  v2Only?: boolean;
};

export const petAnimationRows: readonly PetAnimationRow[] = [
  { id: "idle", label: "Idle", row: 0, frames: 6, action: "idle" },
  { id: "running-right", label: "Run right", row: 1, frames: 8, action: "running-right" },
  { id: "running-left", label: "Run left", row: 2, frames: 8, action: "running-left" },
  { id: "waving", label: "Waving", row: 3, frames: 4, action: "waving" },
  { id: "jumping", label: "Jumping", row: 4, frames: 5, action: "jumping" },
  { id: "failed", label: "Failed", row: 5, frames: 8, action: "failed" },
  { id: "waiting", label: "Waiting", row: 6, frames: 6, action: "waiting" },
  { id: "running", label: "Running", row: 7, frames: 6, action: "running" },
  { id: "review", label: "Review", row: 8, frames: 6, action: "review" },
  { id: "look-right-side", label: "Look around · Right side", row: 9, frames: 8, v2Only: true },
  { id: "look-left-side", label: "Look around · Left side", row: 10, frames: 8, v2Only: true },
];

export function animationRowsFor(version: 1 | 2): PetAnimationRow[] {
  return petAnimationRows.filter((row) => !row.v2Only || version === 2);
}

export function petPreviewURL(api: DashboardAPI, petID: string, query?: Record<string, string>) {
  return api.assetURL(`pets/${encodeURIComponent(petID)}/preview`, query);
}

export function petSpritesheetURL(api: DashboardAPI, petID: string) {
  return api.assetURL(`pets/${encodeURIComponent(petID)}/spritesheet`);
}

export function PetSpritePreview({
  api,
  pet,
  row,
  className = "pets-stage",
  label,
  scale = 1,
}: {
  api: DashboardAPI;
  pet: PetInfo;
  row: PetAnimationRow;
  className?: string;
  label?: string;
  /** Display scale relative to the 192×208 atlas cell. */
  scale?: number;
}) {
  const [sheetReady, setSheetReady] = useState(false);
  const [sheetFailed, setSheetFailed] = useState(false);
  const sheetURL = petSpritesheetURL(api, pet.id);
  const duration = Math.max(row.frames * 0.14, 1.1);
  const ariaLabel = label ?? `${pet.name} ${row.label} preview`;
  const cellW = Math.max(1, Math.round(PET_CELL * scale));
  const cellH = Math.max(1, Math.round(PET_CELL_H * scale));
  const atlasRows = pet.version === 2 ? 11 : 9;
  const atlasWidth = Math.round(PET_CELL * 8 * scale);
  const atlasHeight = Math.round(PET_CELL_H * atlasRows * scale);

  useEffect(() => {
    setSheetReady(false);
    setSheetFailed(false);
    let cancelled = false;
    const image = new Image();
    image.onload = () => { if (!cancelled) setSheetReady(true); };
    image.onerror = () => { if (!cancelled) setSheetFailed(true); };
    image.src = sheetURL;
    if (image.complete && image.naturalWidth > 0) setSheetReady(true);
    return () => { cancelled = true; };
  }, [sheetURL, pet.id]);

  if (sheetFailed || !sheetReady) {
    return (
      <FrameCyclingPreview
        api={api}
        pet={pet}
        row={row}
        className={className}
        label={ariaLabel}
        cellW={cellW}
        cellH={cellH}
      />
    );
  }

  const rootStyle = scale === 1 ? undefined : { width: cellW, height: cellH };

  return (
    <div className={className} aria-label={ariaLabel} style={rootStyle}>
      <div
        className="pets-sprite"
        style={{
          width: cellW,
          height: cellH,
          backgroundImage: `url(${sheetURL})`,
          "--sprite-row": row.row,
          "--sprite-frames": row.frames,
          "--sprite-duration": `${duration}s`,
          "--sprite-cell-w": `${cellW}px`,
          "--sprite-cell-h": `${cellH}px`,
          "--sprite-atlas-width": `${atlasWidth}px`,
          "--sprite-atlas-height": `${atlasHeight}px`,
        } as CSSProperties}
      />
    </div>
  );
}

function FrameCyclingPreview({
  api,
  pet,
  row,
  className,
  label,
  cellW,
  cellH,
}: {
  api: DashboardAPI;
  pet: PetInfo;
  row: PetAnimationRow;
  className: string;
  label: string;
  cellW: number;
  cellH: number;
}) {
  const [frame, setFrame] = useState(0);
  const [frameFailed, setFrameFailed] = useState(false);

  useEffect(() => {
    setFrame(0);
    setFrameFailed(false);
    const timer = window.setInterval(() => {
      setFrame((current) => (current + 1) % row.frames);
    }, 160);
    return () => window.clearInterval(timer);
  }, [pet.id, row.id, row.frames]);

  const query = { row: String(row.row), column: String(frame) };

  const rootStyle = cellW === PET_CELL && cellH === PET_CELL_H ? undefined : { width: cellW, height: cellH };

  if (frameFailed) {
    return (
      <div
        className={`${className} pets-sprite-missing`}
        aria-label={label}
        style={{ width: cellW, height: cellH }}
      />
    );
  }

  return (
    <div className={className} aria-label={label} style={rootStyle}>
      <img
        className="pets-sprite-fallback"
        src={petPreviewURL(api, pet.id, query)}
        alt=""
        width={cellW}
        height={cellH}
        draggable={false}
        onError={() => setFrameFailed(true)}
      />
    </div>
  );
}
