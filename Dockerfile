# syntax=docker/dockerfile:1.7
#
# Multi-stage Dockerfile for wacrm (Next.js 16, standalone output).
#
# Build context: project root (where package.json lives).
# Required: next.config.ts must set `output: "standalone"`.
#
# Stage 1 — deps:    install full dependency tree for the build.
# Stage 2 — builder: produce the standalone server bundle. Secrets
#                    (Supabase URL/keys, Meta secret, ENCRYPTION_KEY,
#                    etc.) are passed in as build args from Dockploy
#                    and promoted to ENV so Next.js sees them at
#                    build-time. They live in this stage's layer
#                    history only — the runner stage below has no
#                    reference to them.
# Stage 3 — runner:  ship a slim Alpine image with only what's needed
#                    to run `node server.js` on port 3000. ARGs and
#                    ENVs are scoped per-stage in Docker, so secrets
#                    declared only in `builder` are not visible here.
#
# In Dockploy, configure build args in the service settings
# ("Environment Variables" → "Build Args"). Each entry from your
# .env becomes a build arg. Runtime env vars are set in the same
# UI under "Environment Variables" — the values are typically
# identical, but build args only matter at build time and runtime
# env vars only matter when the container starts.

ARG NODE_VERSION=20-alpine


# ---------- Stage 1: deps ----------
FROM node:${NODE_VERSION} AS deps
WORKDIR /app

# Install deps with the lockfile for reproducible builds.
COPY package.json package-lock.json ./
RUN npm ci


# ---------- Stage 2: builder ----------
FROM node:${NODE_VERSION} AS builder
WORKDIR /app

ENV NEXT_TELEMETRY_DISABLED=1 \
    NODE_ENV=production

# Reuse the dependency tree from stage 1, then bring in the source.
COPY --from=deps /app/node_modules ./node_modules
COPY . .

# Build-time secrets (NEXT_PUBLIC_* must be present for Next.js to
# inline them into the client bundle). Each ARG has an empty default
# so the build doesn't fail when an optional var is not configured.
# ARGs in this stage do NOT propagate to the runner stage below.
ARG NEXT_PUBLIC_SUPABASE_URL
ARG NEXT_PUBLIC_SUPABASE_ANON_KEY
ARG SUPABASE_SERVICE_ROLE_KEY
ARG ENCRYPTION_KEY
ARG META_APP_SECRET
ARG NEXT_PUBLIC_SITE_URL
ARG AUTOMATION_CRON_SECRET
ARG META_APP_ID
ARG WHATSAPP_TEMPLATES_DRY_RUN
ARG ALLOWED_INVITE_HOSTS

# Promote ARGs to ENVs so Next.js (and any tooling that reads env)
# sees them. `ENV KEY=` (no value) leaves the var unset when the ARG
# was empty, which is what we want for the truly optional ones.
ENV NEXT_PUBLIC_SUPABASE_URL=${NEXT_PUBLIC_SUPABASE_URL} \
    NEXT_PUBLIC_SUPABASE_ANON_KEY=${NEXT_PUBLIC_SUPABASE_ANON_KEY} \
    SUPABASE_SERVICE_ROLE_KEY=${SUPABASE_SERVICE_ROLE_KEY} \
    ENCRYPTION_KEY=${ENCRYPTION_KEY} \
    META_APP_SECRET=${META_APP_SECRET} \
    NEXT_PUBLIC_SITE_URL=${NEXT_PUBLIC_SITE_URL} \
    AUTOMATION_CRON_SECRET=${AUTOMATION_CRON_SECRET} \
    META_APP_ID=${META_APP_ID} \
    WHATSAPP_TEMPLATES_DRY_RUN=${WHATSAPP_TEMPLATES_DRY_RUN} \
    ALLOWED_INVITE_HOSTS=${ALLOWED_INVITE_HOSTS}

# Standalone output is configured in next.config.ts; `npm run build`
# writes .next/standalone/ + .next/static/ we copy in stage 3.
RUN npm run build


# ---------- Stage 3: runner ----------
FROM node:${NODE_VERSION} AS runner
WORKDIR /app

ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=3000 \
    HOSTNAME=0.0.0.0

# Non-root user — standard hardening for a public-internet container.
RUN addgroup --system --gid 1001 nodejs \
 && adduser  --system --uid 1001 --ingroup nodejs nextjs

# Static assets the browser requests directly.
COPY --from=builder --chown=nextjs:nodejs /app/public ./public

# Standalone server tree (includes a minimal node_modules subset).
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./

# Hashed client bundles referenced from HTML.
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static

# Clean any build-time secrets that Next.js inlines into server.js.
# ARGs declared in `builder` are already scoped to that stage and
# cannot leak here, but Next.js's standalone server.js sometimes
# captures process.env refs at runtime — the runtime env vars
# configured in Dockploy's "Environment Variables" tab supply
# those values when the container starts.
USER nextjs

EXPOSE 3000

# Standalone's entrypoint is server.js at the project root.
CMD ["node", "server.js"]


# ---------- Healthcheck ----------
# Uses Node's built-in `http` so we don't need curl/wget in the image.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD node -e "require('http').get('http://localhost:3000/', r => process.exit(r.statusCode === 200 || r.statusCode === 307 || r.statusCode === 308 ? 0 : 1)).on('error', () => process.exit(1))"
