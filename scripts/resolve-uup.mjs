import { createWriteStream } from "node:fs";
import { mkdir, writeFile } from "node:fs/promises";
import { basename, join } from "node:path";
import { pipeline } from "node:stream/promises";

const API_BASE = "https://api.uupdump.net";
const WEB_BASE = "https://uupdump.net";
const TARGETS = {
  "win11-25h2": {
    label: "Windows 11 25H2",
    search: "Windows 11 25H2",
    edition: "ALL",
    titlePattern: /^Windows 11, version 25H2/i
  },
  "win11-26h1": {
    label: "Windows 11 26H1",
    search: "Windows 11 26H1",
    edition: "ALL",
    titlePattern: /^Windows 11, version 26H1/i
  },
  "win11-ltsc-2024": {
    label: "Windows 11 LTSC 2024",
    search: "Windows 11 LTSC 2024",
    edition: "LTSC",
    titlePattern: /LTSC|Enterprise/i
  },
  "win10-22h2": {
    label: "Windows 10 22H2",
    search: "Windows 10 22H2",
    edition: "ALL",
    titlePattern: /Feature update to Windows 10, version 22H2/i
  },
  "win10-ltsc-2021": {
    label: "Windows 10 LTSC 2021",
    search: "Windows 10 LTSC 2021",
    edition: "LTSC",
    titlePattern: /LTSC|Enterprise/i
  }
};

const args = parseArgs(process.argv.slice(2));
const targetId = (args.target ?? process.env.UUP_TARGET ?? "").toLowerCase();
const target = targetId ? TARGETS[targetId] : null;
if (targetId && !target) {
  throw new Error(`Unknown target "${targetId}". Available targets: ${Object.keys(TARGETS).join(", ")}`);
}

const arch = (args.arch ?? process.env.UUP_ARCH ?? "amd64").toLowerCase();
const search = args.search ?? process.env.UUP_SEARCH ?? target?.search ?? "Windows 11 25H2";
const language = (args.lang ?? process.env.UUP_LANG ?? "zh-cn").toLowerCase();
const editionInput = (args.edition ?? process.env.UUP_EDITION ?? target?.edition ?? "ALL").toUpperCase();
const requestedEdition = editionInput === "LTSC" ? "ENTERPRISES,IOTENTERPRISES" : editionInput;
const imageFormat = (args.imageFormat ?? process.env.UUP_IMAGE_FORMAT ?? "wim").toLowerCase();
const includeUpdates = parseBoolean(args.includeUpdates ?? process.env.UUP_INCLUDE_UPDATES ?? "1");
const cleanup = parseBoolean(args.cleanup ?? process.env.UUP_CLEANUP ?? "0");
const netFx3 = parseBoolean(args.netFx3 ?? process.env.UUP_NETFX3 ?? "0");
const outDir = args.outDir ?? process.env.UUP_OUT_DIR ?? "uup-work";

if (!["wim", "esd"].includes(imageFormat)) {
  throw new Error(`Unknown image format "${imageFormat}". Available: wim, esd`);
}

await mkdir(outDir, { recursive: true });

const build = await findLatestBuild(search, arch, target?.titlePattern);
await ensureLanguage(build.uuid, language);
const editions = await resolveEditions(build.uuid, language, requestedEdition);
const editionParam = editions.map((item) => item.toLowerCase()).join(";");
const editionName = editionInput === "ALL" ? "all" : editionInput.toLowerCase();

const zipUrl = `${WEB_BASE}/get.php?id=${encodeURIComponent(build.uuid)}&pack=${encodeURIComponent(language)}&edition=${encodeURIComponent(editionParam)}&autodl=2`;
const zipPath = join(outDir, `uup-${safeName(build.build)}-${arch}-${language}-${editionName}.zip`);
await download(zipUrl, zipPath);

const metadata = {
  title: build.title,
  target: targetId || "custom",
  targetLabel: target?.label ?? "Custom",
  search,
  build: build.build,
  arch,
  uuid: build.uuid,
  language,
  editionInput,
  editions,
  convertOptions: {
    includeUpdates,
    cleanup,
    netFx3,
    imageFormat,
    solidCompression: imageFormat === "esd"
  },
  zipPath,
  zipFile: basename(zipPath),
  source: "https://uupdump.net/",
  createdUnix: build.created
};

await writeFile(join(outDir, "metadata.json"), `${JSON.stringify(metadata, null, 2)}\n`);
console.log(JSON.stringify(metadata, null, 2));

function parseArgs(argv) {
  const result = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!arg.startsWith("--")) continue;
    const key = arg.slice(2);
    const value = argv[i + 1] && !argv[i + 1].startsWith("--") ? argv[++i] : "true";
    result[key] = value;
  }
  return result;
}

function parseBoolean(value) {
  return ["1", "true", "yes", "on"].includes(String(value).toLowerCase());
}

async function getJson(url) {
  const response = await fetch(url, {
    headers: { "user-agent": "uup-auto-build/1.0" }
  });

  if (!response.ok) {
    throw new Error(`Request failed ${response.status}: ${url}`);
  }

  const json = await response.json();
  if (!json.response) {
    throw new Error(`Unexpected UUP dump API response from ${url}`);
  }

  return json.response;
}

async function findLatestBuild(query, wantedArch, titlePattern) {
  const url = `${API_BASE}/listid.php?search=${encodeURIComponent(query)}&sortByDate=1`;
  const response = await getJson(url);
  const builds = Object.values(response.builds ?? {});
  const candidates = builds
    .filter((item) => item.arch?.toLowerCase() === wantedArch)
    .filter((item) => titlePattern ? titlePattern.test(item.title ?? "") : isInstallBuild(item.title ?? ""))
    .sort((a, b) => Number(b.created ?? 0) - Number(a.created ?? 0));

  if (candidates.length === 0) {
    throw new Error(`No build found for search="${query}" arch="${wantedArch}"`);
  }

  return candidates[0];
}

function isInstallBuild(title) {
  return /^Windows \d+/i.test(title) || /Feature update to Windows \d+/i.test(title);
}

async function ensureLanguage(id, lang) {
  const response = await getJson(`${API_BASE}/listlangs.php?id=${encodeURIComponent(id)}`);
  const languages = response.langList ?? [];
  if (!languages.includes(lang)) {
    throw new Error(`Language "${lang}" is not available. Available: ${languages.join(", ")}`);
  }
}

async function resolveEditions(id, lang, wantedEdition) {
  const url = `${API_BASE}/listeditions.php?id=${encodeURIComponent(id)}&lang=${encodeURIComponent(lang)}`;
  const response = await getJson(url);
  const editions = response.editionList ?? [];
  if (wantedEdition === "ALL") {
    if (editions.length === 0) {
      throw new Error(`No editions are available for language "${lang}".`);
    }

    return editions;
  }

  const requested = wantedEdition.split(",").map((item) => item.trim()).filter(Boolean);
  const unavailable = requested.filter((item) => !editions.includes(item));
  if (unavailable.length > 0) {
    throw new Error(`Edition "${unavailable.join(", ")}" is not available from UUP dump for this build/language. Use ALL or one of: ${editions.join(", ")}`);
  }

  return requested;
}

async function download(url, path) {
  let response;
  for (let attempt = 1; attempt <= 5; attempt += 1) {
    response = await fetch(url, {
      headers: { "user-agent": "uup-auto-build/1.0" }
    });

    if (response.ok || ![429, 500, 502, 503, 504].includes(response.status)) {
      break;
    }

    const waitMs = attempt * 15000;
    console.warn(`Download attempt ${attempt} failed with ${response.status}; retrying in ${waitMs / 1000}s.`);
    await new Promise((resolve) => setTimeout(resolve, waitMs));
  }

  if (!response.ok) {
    throw new Error(`Failed to download UUP script package ${response.status}: ${url}`);
  }

  const contentType = response.headers.get("content-type") ?? "";
  if (!contentType.includes("zip")) {
    throw new Error(`Expected a zip package, got "${contentType}" from ${url}`);
  }

  await pipeline(response.body, createWriteStream(path));
}

function safeName(value) {
  return String(value).replace(/[^a-z0-9._-]+/gi, "_");
}
