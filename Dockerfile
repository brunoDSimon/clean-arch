# ── Stage 1: Build ──────────────────────────────────────────────────────────
FROM node:24-alpine AS build
WORKDIR /app
ENV NODE_OPTIONS=--max-old-space-size=4096

COPY package.json package-lock.json ./
RUN npm ci --legacy-peer-deps && npm cache clean --force

COPY . .
RUN npx ng build --configuration=production

# ── Stage 2: Serve ──────────────────────────────────────────────────────────
FROM nginx:1.27-alpine

RUN rm /etc/nginx/conf.d/default.conf

# Non-root user
RUN addgroup -g 1001 -S appgroup && \
    adduser -S appuser -u 1001 -G appgroup

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build --chown=appuser:appgroup /app/dist/vida-fit-dashboard/browser /usr/share/nginx/html

# Criar pasta old/ com cópia dos arquivos (fallback pós-deploy)
# Essa pasta NÃO é atualizada a cada deploy — mantém versão anterior
RUN mkdir -p /usr/share/nginx/html/old && \
    cp -r /usr/share/nginx/html/*.js /usr/share/nginx/html/old/ 2>/dev/null || true && \
    cp -r /usr/share/nginx/html/*.css /usr/share/nginx/html/old/ 2>/dev/null || true && \
    chown -R appuser:appgroup /usr/share/nginx/html/old

# Permissões pro nginx (porta 80 precisa de root pra bind, mas conteúdo é do user)
# default.conf incluído aqui de propósito: o entrypoint padrão da imagem nginx roda
# (10-listen-on-ipv6-by-default.sh) como appuser e tenta editar esse arquivo pra adicionar
# `listen [::]:80` — sem isso ele falhava silenciosamente ("can not modify ... read-only
# file system?", achado em produção 2026-07-29) e o nginx ficava escutando só em IPv4.
# O healthcheck abaixo já não depende mais disso (usa 127.0.0.1 direto), mas corrigir aqui
# evita o container ficar com IPv4/IPv6 assimétrico por baixo.
RUN chown -R appuser:appgroup /usr/share/nginx/html && \
    chown -R appuser:appgroup /var/cache/nginx && \
    chown -R appuser:appgroup /var/log/nginx && \
    chown appuser:appgroup /etc/nginx/conf.d/default.conf && \
    touch /var/run/nginx.pid && \
    chown appuser:appgroup /var/run/nginx.pid

USER appuser

EXPOSE 80

# 127.0.0.1 explícito, não "localhost" — em containers Alpine/musl "localhost" pode resolver
# pra ::1 (IPv6) primeiro, e se o nginx só estiver escutando em IPv4 (ver comentário acima),
# o healthcheck falha com "connection refused" mesmo com o nginx 100% saudável em IPv4.
# Bug real que derrubou um deploy em produção (2026-07-29) antes dessa correção.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -qO- http://127.0.0.1:80/ || exit 1

CMD ["nginx", "-g", "daemon off;"]
