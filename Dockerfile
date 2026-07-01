# syntax=docker/dockerfile:1.7
#
# Multi-stage Dockerfile for wacrm (Next.js 16, standalone output).
#
# Build context: project root (where package.json lives).
# Required: next.config.ts must set `output: "standalone"`.
#
# Stage 1 — deps:   install full dependency tree for the build.
# Stage 2 — builder: produce the standalone server bundle. Secrets
#                   (Supabase URL/keys, Meta secret, ENCRYPTION_KEY,
#                   etc.) are loaded at build-time from a BuildKit
#                   secret file so they never land in the image.
# Stage 3 — runner:  ship a slim Alpine image with only what's needed
#                   to run `node server.js` on port 3000.
#
# In Dockploy, configure build secrets in the service settings
# ("Environment Variables" / "Build Secrets"). The .env file in the
# repo is NEVER copied into the image — it's only consumed by the
# builder stage as a mounted secret.

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

# Load the secrets file as a BuildKit secret into /tmp/.env. This
# path is never copied into the final image — only this layer's
# `npm run build` invocation sees it, which is exactly what we want
# because Next.js inlines NEXT_PUBLIC_* vars into the client bundle
# at build time.
#
# Usage in Dockploy: mount `.env` (or a key=value list) as the
# `env_file` build secret.
RUN --mount=type=secret,id=env_file,target=/tmp/.env \
    set -a && . /tmp/.env && set +a && npm run build


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

USER nextjs

EXPOSE 3000

# Standalone's entrypoint is server.js at the project root.
CMD ["node", "server.js"]


# ---------- Healthcheck ----------
# Uses Node's built-in `http` so we don't need curl/wget in the image.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD node -e "require('http').get('http://localhost:3000/', r => process.exit(r.statusCode === 200 || r.statusCode === 307 || r.statusCode === 308 ? 0 : 1)).on('error', () => process.exit(1))"
