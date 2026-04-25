# Команды заливки на сервер

Сервер: `root@194.67.84.155`  
Выполнять из корня проекта: `c:\Users\user\CascadeProjects\2048`

---

## Вариант 1: Через Git (рекомендуется)

**Локально (PowerShell):**
```powershell
cd c:\Users\user\CascadeProjects\2048
git add -A
git commit -m "описание изменений"
git push
```

**На сервере (SSH):**
```bash
ssh root@194.67.84.155
cd /opt/prosto-taxi
git pull
docker compose build api
docker compose up -d api nginx
```

**Если менялась админка (перезагрузка nginx по имени контейнера):**
```bash
docker exec prosto_nginx nginx -s reload
```

> Сервис в compose называется **nginx**, контейнер — **prosto_nginx**. Без `package-lock.json` сборка идёт через `npm install` (не `npm ci`).

---

## Вариант 2: Через SCP (залить файлы напрямую)

**API (бэкенд) — изменённые файлы:**
```powershell
cd c:\Users\user\CascadeProjects\2048

scp backend_vps\api\src\events.gateway.ts root@194.67.84.155:/opt/prosto-taxi/api/src/
scp backend_vps\api\src\admin.controller.ts root@194.67.84.155:/opt/prosto-taxi/api/src/
scp backend_vps\api\src\drivers.service.ts root@194.67.84.155:/opt/prosto-taxi/api/src/
scp backend_vps\api\src\drivers.controller.ts root@194.67.84.155:/opt/prosto-taxi/api/src/
```

**Админка:**
```powershell
scp prosto_taxi_driver\android\admin.html root@194.67.84.155:/opt/prosto-taxi/prosto_taxi_driver/android/admin.html
```

**После SCP — на сервере перезапуск API и nginx:**
```bash
ssh root@194.67.84.155
cd /opt/prosto-taxi
docker compose build api
docker compose up -d api nginx
docker exec prosto_nginx nginx -s reload
```

---

## Проверка после заливки

```bash
docker compose ps
docker compose logs --tail=50 api
curl -fsS https://api.trezv7777.ru/api/health
```
