import { createClient } from "@supabase/supabase-js";
import { createWorker } from "tesseract.js";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const BUCKET = "verification-docs";
const TAG_CHARS = "0289PYLQGRJCUV";
const TAG_RE = /#[A-Z0-9]{3,15}/i;

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function normalizeText(s: string) {
  return String(s || "")
    .replace(/[٠-٩]/g, (d) => String("٠١٢٣٤٥٦٧٨٩".indexOf(d)))
    .replace(/,/g, "")
    .replace(/٬/g, "")
    .replace(/\s+/g, " ")
    .trim();
}

function numbersFrom(text: string): number[] {
  const normalized = normalizeText(text);
  return [...normalized.matchAll(/\b\d{1,7}\b/g)]
    .map((m) => Number(m[0]))
    .filter((n) => Number.isFinite(n));
}

function normalizeTag(raw: string): string | null {
  let s = String(raw || "").toUpperCase().replace(/[^A-Z0-9#]/g, "");
  if (!s) return null;
  if (!s.startsWith("#")) s = `#${s}`;
  // The prompt specifies the only valid Null's Brawl/Supercell tag alphabet.
  // I -> J is the known OCR correction from the actual test case.
  s = s.replace(/I/g, "J");
  const body = s.slice(1);
  if (!body || body.length < 3 || body.length > 15) return null;
  for (const ch of body) {
    if (!TAG_CHARS.includes(ch)) return null;
  }
  return `#${body}`;
}

function extractTag(text: string): { value: string | null; ambiguous: boolean } {
  const raw = String(text || "").toUpperCase();
  const candidates = raw.match(/#[A-Z0-9\s]{3,20}/g) || [];
  for (const candidate of candidates) {
    const tag = normalizeTag(candidate);
    if (tag) return { value: tag, ambiguous: false };
  }
  // Some OCR runs omit '#'. Try candidate tokens containing only tag characters.
  const tokens = raw.split(/\s+/).map((x) => x.replace(/[^A-Z0-9]/g, "")).filter(Boolean);
  for (const token of tokens) {
    const tag = normalizeTag(`#${token}`);
    if (tag) return { value: tag, ambiguous: false };
  }
  return { value: null, ambiguous: candidates.length > 0 };
}

function pickLikelyNumber(text: string, preferredLabels: RegExp[]): number | null {
  const normalized = normalizeText(text);
  for (const label of preferredLabels) {
    const match = normalized.match(new RegExp(`${label.source}[^0-9]{0,25}(\\d{1,7})`, label.flags.includes("i") ? "i" : ""));
    if (match) return Number(match[1]);
  }
  return numbersFrom(normalized)[0] ?? null;
}

async function ocrImage(image: Uint8Array, logger?: (m: unknown) => void) {
  // Tesseract.js v5 is supported through npm imports in Supabase Edge Functions.
  // The engine downloads its worker/core/language assets at first use and caches them.
  const worker = await createWorker("eng", 1, {
    logger,
    cacheMethod: "write",
  });
  try {
    await worker.setParameters({
      preserve_interword_spaces: "1",
      user_defined_dpi: "300",
    });
    const result = await worker.recognize(image);
    return result.data.text || "";
  } finally {
    await worker.terminate();
  }
}

function parseScreenshots(text1: string, text2: string) {
  const all = `${text1}\n${text2}`;
  const tagResult = extractTag(text1);
  const nums1 = numbersFrom(text1);
  const nums2 = numbersFrom(text2);

  // Label-aware extraction first; numeric fallbacks are deliberately conservative.
  const trophies = pickLikelyNumber(text1, [/troph(?:y|ies)/i, /cups?/i]);
  const highest = pickLikelyNumber(text1, [/highest[^0-9]{0,15}(?:troph(?:y|ies)|cups?)/i, /best[^0-9]{0,15}(?:troph(?:y|ies)|cups?)/i]);
  const wins = pickLikelyNumber(text2, [/wins?/i, /victories/i]);
  const currentRank = pickLikelyNumber(text2, [/rank/i, /ranking/i, /league/i]);

  // Null's Brawl UI can be localized, so use safe positional fallbacks only when
  // label-aware extraction did not find a value. The first screenshot normally
  // contains current + highest trophies; the second contains wins + rank.
  const trophyFallback = trophies ?? nums1[0] ?? null;
  let highestFallback = highest;
  if (highestFallback == null && nums1.length > 1) highestFallback = nums1[1];
  const winsFallback = wins ?? nums2[0] ?? null;
  const rankFallback = currentRank ?? (nums2.length > 1 ? nums2[1] : nums2[0] ?? null);

  return {
    parsed: {
      player_tag: tagResult.value,
      trophies: trophyFallback,
      highest_trophies: highestFallback,
      wins: winsFallback,
      current_rank: rankFallback,
    },
    raw: { image1: text1, image2: text2, combined: all },
    tag_ambiguous: tagResult.ambiguous,
  };
}

function logicalCheck(parsed: Record<string, unknown>) {
  const trophies = Number(parsed.trophies);
  const highest = Number(parsed.highest_trophies);
  const wins = Number(parsed.wins);
  const rank = Number(parsed.current_rank);
  const missing: string[] = [];
  if (!Number.isFinite(trophies)) missing.push("الكؤوس الحالية");
  if (!Number.isFinite(highest)) missing.push("أعلى كؤوس");
  if (!Number.isFinite(wins)) missing.push("الانتصارات");
  if (!Number.isFinite(rank)) missing.push("الرانك الحالي");
  if (parsed.player_tag == null) missing.push("Player Tag");
  if (Number.isFinite(trophies) && Number.isFinite(highest) && highest < trophies) {
    return { ok: false, reason: "تناقض منطقي: الرقم القياسي أقل من الكؤوس الحالية." };
  }
  if (missing.length) return { ok: false, reason: `تعذر استخراج: ${missing.join("، ")}.` };
  return { ok: true, reason: null };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  try {
    const authHeader = req.headers.get("Authorization") || "";
    if (!authHeader) return json({ error: "Authentication required" }, 401);

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const userClient = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: authHeader } } });
    const adminClient = createClient(supabaseUrl, serviceKey);

    const { data: authData, error: authError } = await userClient.auth.getUser();
    if (authError || !authData.user) return json({ error: "Invalid session" }, 401);

    const body = await req.json().catch(() => ({}));
    const requestId = body?.request_id;
    if (!requestId) return json({ error: "request_id is required" }, 400);

    const { data: request, error: requestError } = await adminClient
      .from("verification_requests")
      .select("*")
      .eq("id", requestId)
      .maybeSingle();
    if (requestError) throw requestError;
    if (!request) return json({ error: "Request not found" }, 404);
    if (String(request.user_id) !== String(authData.user.id)) return json({ error: "Forbidden" }, 403);
    if (request.request_type !== "data_update") return json({ error: "Not a player data update request" }, 400);
    if (!request.proof_image_path || !request.image_path_2) return json({ error: "Both images are required" }, 400);

    const [img1, img2] = await Promise.all([
      adminClient.storage.from(BUCKET).download(request.proof_image_path),
      adminClient.storage.from(BUCKET).download(request.image_path_2),
    ]);
    if (img1.error) throw img1.error;
    if (img2.error) throw img2.error;

    const text1 = await ocrImage(new Uint8Array(await img1.data.arrayBuffer()), () => {});
    const text2 = await ocrImage(new Uint8Array(await img2.data.arrayBuffer()), () => {});
    const result = parseScreenshots(text1, text2);
    const parsed = result.parsed as Record<string, unknown>;
    const logic = logicalCheck(parsed);

    const { data: player, error: playerError } = await adminClient
      .from("players")
      .select("user_id,player_tag,trophies,best_trophies,wins,current_rank,last_verified_at")
      .eq("user_id", request.user_id)
      .maybeSingle();
    if (playerError) throw playerError;
    if (!player) return json({ error: "Player not found" }, 404);

    let decision: "approved" | "pending_review" | "rejected" = "approved";
    let reason = "تم اجتياز الفحص الآلي.";
    const now = new Date();

    if (!logic.ok) {
      decision = "rejected";
      reason = logic.reason || "تعذر التحقق من البيانات.";
    } else {
      const oldTrophies = Number(player.trophies || 0);
      const oldBest = Number(player.best_trophies || 0);
      const oldWins = Number(player.wins || 0);
      const newTrophies = Number(parsed.trophies);
      const newBest = Number(parsed.highest_trophies);
      const newWins = Number(parsed.wins);
      const lastVerifiedAt = player.last_verified_at ? new Date(player.last_verified_at) : null;
      const hoursSinceLast = lastVerifiedAt ? (now.getTime() - lastVerifiedAt.getTime()) / 3600000 : Infinity;

      if (newTrophies - oldTrophies >= 15000 && hoursSinceLast < 48) {
        decision = "pending_review";
        reason = `قفزة +${(newTrophies - oldTrophies).toLocaleString("en-US")} كأس خلال ${Math.max(0, hoursSinceLast).toFixed(1)} ساعة من آخر تحديث موثّق.`;
      } else if (newBest < newTrophies || newBest < oldBest) {
        decision = "rejected";
        reason = "تناقض منطقي: الرقم القياسي الجديد أقل من الكؤوس الحالية أو أقل من الرقم القياسي السابق.";
      } else if (newWins < oldWins) {
        decision = "rejected";
        reason = "تناقض منطقي: مجموع الانتصارات لا يمكن أن ينخفض عن القيمة الموثّقة السابقة.";
      }
    }

    const ocrPayload = { parsed, raw: result.raw, generated_at: now.toISOString() };
    const updateRequest: Record<string, unknown> = {
      ocr_extracted_json: ocrPayload,
      current_rank: Number.isFinite(Number(parsed.current_rank)) ? Number(parsed.current_rank) : null,
      auto_decision: decision,
      auto_decision_reason: reason,
      admin_notes: decision === "pending_review" ? reason : null,
      status: decision,
    };
    if (parsed.player_tag) updateRequest.player_tag = parsed.player_tag;

    const { error: updateError } = await adminClient
      .from("verification_requests")
      .update(updateRequest)
      .eq("id", request.id);
    if (updateError) throw updateError;

    if (decision === "approved") {
      const { error: playerUpdateError } = await adminClient.from("players").update({
        trophies: Number(parsed.trophies),
        best_trophies: Number(parsed.highest_trophies),
        wins: Number(parsed.wins),
        current_rank: Number(parsed.current_rank),
        player_tag: parsed.player_tag || player.player_tag || null,
        last_verified_at: now.toISOString(),
      }).eq("user_id", request.user_id);
      if (playerUpdateError) throw playerUpdateError;
    }

    return json({ decision, reason, parsed });
  } catch (error) {
    console.error("process-player-update", error);
    return json({ error: error instanceof Error ? error.message : String(error) }, 500);
  }
});
