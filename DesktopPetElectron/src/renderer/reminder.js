// src/renderer/reminder.js — 关闭按钮 / 确定按钮均触发 dismiss
'use strict';

function closeReminder() {
  if (window.reminderAPI) window.reminderAPI.close();
}

document.getElementById('close').addEventListener('click', closeReminder);
document.getElementById('ok').addEventListener('click', closeReminder);
