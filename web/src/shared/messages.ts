/**
 * Wire schemas for every message envelope used in the extension.
 * See `contracts/extension-messages.md` (in the paperless-ngx repo) for the
 * canonical contract; this file is the runtime enforcement.
 *
 * Three channels:
 *   1. content <-> background (browser.runtime.sendMessage)
 *   2. popup/settings <-> background (browser.runtime.sendMessage)
 *   3. background <-> native (browser.runtime.sendNativeMessage)
 */
import { z } from "zod";

// ---------------------------------------------------------------------------
// ErrorKind — mirrors shared-swift/Models.swift `ErrorKind`.
// ---------------------------------------------------------------------------

export const ErrorKindSchema = z.enum([
  "notConfigured",
  "httpsRequired",
  "cannotReachServer",
  "authRejected",
  "pageCannotBeCaptured",
  "serverRejectedUpload",
  "tooLarge",
  "cancelled",
  "unknown",
]);
export type ErrorKind = z.infer<typeof ErrorKindSchema>;

// ---------------------------------------------------------------------------
// Channel 1: content <-> background
// ---------------------------------------------------------------------------

export const SerializePageRequestSchema = z.object({
  op: z.literal("serializePage"),
  requestId: z.string().uuid(),
});
export type SerializePageRequest = z.infer<typeof SerializePageRequestSchema>;

export const SerializePageResponseSchema = z.discriminatedUnion("ok", [
  z.object({
    ok: z.literal(true),
    html: z.string(),
    title: z.string(),
    url: z.string().url(),
  }),
  z.object({
    ok: z.literal(false),
    errorKind: z.enum(["pageCannotBeCaptured", "tooLarge", "unknown"]),
    message: z.string(),
  }),
]);
export type SerializePageResponse = z.infer<typeof SerializePageResponseSchema>;

// ---------------------------------------------------------------------------
// Channel 2: popup/settings <-> background
// ---------------------------------------------------------------------------

export const TriggerSaveRequestSchema = z.object({
  op: z.literal("triggerSave"),
  requestId: z.string().uuid(),
  tabId: z.number().int(),
});
export type TriggerSaveRequest = z.infer<typeof TriggerSaveRequestSchema>;

export const TriggerSaveResponseSchema = z.discriminatedUnion("ok", [
  z.object({ ok: z.literal(true), state: z.enum(["started", "alreadyInFlight"]) }),
  z.object({ ok: z.literal(false), errorKind: ErrorKindSchema, message: z.string() }),
]);
export type TriggerSaveResponse = z.infer<typeof TriggerSaveResponseSchema>;

export const SaveCompletedSchema = z.discriminatedUnion("result", [
  z.object({
    op: z.literal("saveCompleted"),
    tabId: z.number().int(),
    result: z.literal("succeeded"),
    sourceURL: z.string().url(),
  }),
  z.object({
    op: z.literal("saveCompleted"),
    tabId: z.number().int(),
    result: z.literal("failed"),
    errorKind: ErrorKindSchema,
    message: z.string(),
    sourceURL: z.string().url(),
  }),
]);
export type SaveCompleted = z.infer<typeof SaveCompletedSchema>;

export const GetStatusRequestSchema = z.object({ op: z.literal("getStatus") });

export const JobStatusSchema = z.discriminatedUnion("state", [
  z.object({
    state: z.literal("queued"),
    sourceURL: z.string().url(),
    title: z.string(),
    queuedAt: z.string(),
  }),
  z.object({
    state: z.literal("succeeded"),
    sourceURL: z.string().url(),
    title: z.string(),
    completedAt: z.string(),
    serverTaskId: z.string(),
  }),
  z.object({
    state: z.literal("failed"),
    sourceURL: z.string().url(),
    title: z.string(),
    failedAt: z.string(),
    errorKind: ErrorKindSchema,
    message: z.string(),
  }),
]);
export type JobStatus = z.infer<typeof JobStatusSchema>;

export const GetStatusResponseSchema = z.object({
  configured: z.boolean(),
  lastVerifiedAt: z.string().nullable(),
  inFlight: z.array(JobStatusSchema),
  lastFailure: JobStatusSchema.nullable(),
  recentSuccesses: z.array(JobStatusSchema),
});
export type GetStatusResponse = z.infer<typeof GetStatusResponseSchema>;

export const DismissLastFailureRequestSchema = z.object({ op: z.literal("dismissLastFailure") });
export const RetryLastFailureRequestSchema = z.object({ op: z.literal("retryLastFailure") });
export const FailureActionResponseSchema = z.discriminatedUnion("ok", [
  z.object({ ok: z.literal(true) }),
  z.object({ ok: z.literal(false), message: z.string() }),
]);

// ---------------------------------------------------------------------------
// Channel 3: background <-> native
// ---------------------------------------------------------------------------

export const GetTokenRequestSchema = z.object({
  op: z.literal("getToken"),
  requestId: z.string().uuid(),
  host: z.string().min(1),
});
export const GetTokenResponseSchema = z.discriminatedUnion("ok", [
  z.object({ ok: z.literal(true), token: z.string() }),
  z.object({
    ok: z.literal(false),
    errorKind: z.enum(["notConfigured", "unknown"]),
    message: z.string(),
  }),
]);

export const RenderAndUploadInitRequestSchema = z.object({
  op: z.literal("renderAndUpload.init"),
  requestId: z.string().uuid(),
  serverURL: z.string().url(),
  title: z.string(),
  sourceURL: z.string().url(),
  capturedAt: z.string(),
  sourceUrlFieldId: z.number().int().nullable(),
  totalChunks: z.number().int().positive(),
  totalBytes: z.number().int().nonnegative(),
});
export const RenderAndUploadInitResponseSchema = z.discriminatedUnion("ok", [
  z.object({ ok: z.literal(true), cachePath: z.string() }),
  z.object({ ok: z.literal(false), errorKind: ErrorKindSchema, message: z.string() }),
]);

export const RenderAndUploadChunkRequestSchema = z.object({
  op: z.literal("renderAndUpload.chunk"),
  requestId: z.string().uuid(),
  chunkIndex: z.number().int().nonnegative(),
  data: z.string(),
});
export const RenderAndUploadChunkResponseSchema = z.discriminatedUnion("ok", [
  z.object({ ok: z.literal(true) }),
  z.object({ ok: z.literal(false), errorKind: ErrorKindSchema, message: z.string() }),
]);

export const RenderAndUploadCommitRequestSchema = z.object({
  op: z.literal("renderAndUpload.commit"),
  requestId: z.string().uuid(),
});
export const RenderAndUploadCommitResponseSchema = z.discriminatedUnion("ok", [
  z.object({ ok: z.literal(true), state: z.literal("queued") }),
  z.object({ ok: z.literal(false), errorKind: ErrorKindSchema, message: z.string() }),
]);

export const GetJobStatusRequestSchema = z.object({ op: z.literal("getJobStatus") });
export const GetJobStatusResponseSchema = z.object({
  inFlight: z.array(JobStatusSchema),
  lastFailure: JobStatusSchema.nullable(),
  recentSuccesses: z.array(JobStatusSchema),
});

export const RevealLastFailureRequestSchema = z.object({
  op: z.literal("revealLastFailure"),
  jobId: z.string().uuid(),
});
export const RevealLastFailureResponseSchema = z.object({ ok: z.literal(true) });

// ---------------------------------------------------------------------------
// Convenience: union of all native-channel inbound requests, useful for
// dispatching on the JS side after a native handler responds.
// ---------------------------------------------------------------------------

export const NativeRequestSchema = z.union([
  GetTokenRequestSchema,
  RenderAndUploadInitRequestSchema,
  RenderAndUploadChunkRequestSchema,
  RenderAndUploadCommitRequestSchema,
  GetJobStatusRequestSchema,
  RevealLastFailureRequestSchema,
]);
export type NativeRequest = z.infer<typeof NativeRequestSchema>;
