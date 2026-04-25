FROM node:20-alpine AS deps
WORKDIR /app
ARG NPM_CMD=install
COPY package*.json ./
RUN npm $NPM_CMD

FROM node:20-alpine AS build
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
COPY tsconfig.json ./
COPY src ./src
# Гарантированная подстановка текста SMS при сборке (на случай старого кэша/контекста)
RUN sed -i 's/Код: \${code}/Ваш код для входа в Трезвый водитель: \${code}/' /app/src/sms.service.ts
RUN npm run build

FROM node:20-alpine
WORKDIR /app
ENV NODE_ENV=production
COPY --from=deps /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
EXPOSE 3000
CMD ["node", "dist/main.js"]
