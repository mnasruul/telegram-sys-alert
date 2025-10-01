# Telegram Sys Alert 🚨

Lightweight shell-based monitor for **CPU & Memory usage**.  
If usage exceeds a threshold (default: 86%), it sends an alert to **Telegram** using a bot.

Works on any Linux machine (VM, baremetal, VPS).  
No Prometheus, no heavy agents — just `bash` + `curl`.

---

## ✨ Features
- Monitors **CPU** and **Memory** usage
- Sends alert to Telegram chat/group
- Runs via **systemd timer** or cron
- Lightweight (bash + curl)
- Configurable threshold & cooldown

---

## 📦 Installation

Clone repo:

```bash
git clone https://github.com/mnasruul/telegram-sys-alert.git
cd telegram-sys-alert
