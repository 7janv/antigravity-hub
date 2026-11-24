# Antigravity Auto-Hub

**Quản lý đa tài khoản, theo dõi quota theo từng model và tự động xoay tài khoản Antigravity Desktop trên Windows — mã hóa DPAPI và cập nhật theo bản phát hành có kiểm chứng SHA-256.**

[![Windows validation](https://github.com/7janv/antigravity-hub/actions/workflows/validate.yml/badge.svg)](https://github.com/7janv/antigravity-hub/actions/workflows/validate.yml)
[![Antigravity Hub](https://img.shields.io/badge/7janv-Antigravity_Hub-0F766E)](https://github.com/7janv/antigravity-hub)

- **Kho mã nguồn & Bản phát hành:** [github.com/7janv/antigravity-hub](https://github.com/7janv/antigravity-hub) · [GitHub Releases](https://github.com/7janv/antigravity-hub/releases)

---

## Tính năng chính & Tăng cường bảo mật

- **Dashboard trực quan (WPF, không cần cài thêm thư viện):**
  - Hiển thị toàn bộ pool tài khoản với gói (**Free / Pro / Ultra**), tìm kiếm, bộ lọc trạng thái, sắp xếp theo cột, nhật ký xoay và **System Tray** (chạy gọn dưới khay hệ thống, có tùy chọn thoát hẳn kể cả daemon nền).
  - Giao diện **Light / AMOLED Dark Mode**, tab **Cài đặt (Settings)** tùy chỉnh ngưỡng xoay, cooldown, thông báo, và nút **Tạm dừng / Bật xoay tự động**.
- **Theo dõi đầy đủ từng dòng model:**
  - **Hạn mức chung:** `Gemini 5 giờ`, `Gemini Tuần`
  - **Nhóm Gemini:** `Gemini Flash`, `Gemini Neon`, `Gemini Argon`, `Gemini Hydrogen`, `Gemini Carbon`
  - **Nhóm Claude & GPT:** `Claude Opus`, `Claude Sonnet`, `GPT-OSS 120B`
  - Phân biệt rõ **0%** (hết quota thật) với **vòng nét đứt (`—`)** (chưa được cấp / bị tắt hoặc chưa có dữ liệu). Bấm **ⓘ** để xem chi tiết biến thể, Orchestrator và thời điểm reset theo giờ máy.
- **Mã hóa DPAPI cho tài khoản & cấu hình OAuth:**
  - Credential tài khoản trong `accounts/*.json` được mã hóa bằng **Windows DPAPI (`dpapi-v1`, CurrentUser)** kèm quyền NTFS chỉ cho phép tài khoản Windows hiện tại. Tương thích ngược đọc các file plaintext cũ và tự nâng cấp khi lưu lại.
  - Cấu hình OAuth (`oauth.local.clixml`) lưu bằng Windows DPAPI với quyền NTFS chỉ dành cho user hiện tại.
- **Bộ nhớ đệm OAuth 30 phút & Giảm tải quét nền:**
  - Bộ nhớ đệm `access_token` **30 phút (`1800` giây)** (giới hạn bởi `expires_in - 60`, tự động làm mới khi gặp HTTP `401`) giúp giảm mạnh số lượt gọi `oauth2.googleapis.com/token`.
  - Chu kỳ quét daemon mặc định **30 giây** (`-IntervalSeconds 30`).
  - Tùy chọn **Tạm dừng quét khi đóng IDE (`PauseScanWhenIdeClosed`, bật mặc định):** khi Antigravity Desktop đóng, daemon bỏ qua toàn bộ lời gọi API Google (gồm cả chế độ xoay CLI) và chỉ ghi log một lần mỗi khi chuyển trạng thái.
- **Xoay tài khoản tự động & an toàn (hỗ trợ Antigravity 2.34+):**
  - Đọc trực tiếp model đang chọn trong IDE, chỉ xoay khi quota dưới ngưỡng cấu hình (mặc định 20%), IDE rảnh, không có bản nháp đang soạn dở và qua thời gian cooldown (mặc định 120 giây).
  - Dự phòng khôi phục khi sự cố đăng nhập (`.login-backup.dpapi` mã hóa DPAPI) và chỉ quản lý đúng tiến trình daemon thuộc thư mục cài đặt hiện tại.
- **Trình cập nhật bản phát hành an toàn (Safe Release Updater):**
  - Chạy thủ công từ tab **Cài đặt**, chỉ đọc bản phát hành gắn tag `vX.Y.Z` từ `https://api.github.com/repos/7janv/antigravity-hub/releases/latest` (không kéo nhánh `main` chưa kiểm chứng, không chạy `git reset --hard`).
  - Kiểm chứng đầy đủ **SHA-256** của tệp nén `.zip`, `release-manifest.json`, `SHA256SUMS.txt` và từng tệp bên trong; kiểm tra chống Zip-Slip và cổng kiểm tra tĩnh (chặn tệp thực thi `.exe/.dll`, ký tự BiDi ẩn, mã nguy hiểm, URL ngoài danh sách cho phép).
  - Hiển thị phiên bản, Commit SHA, liên kết so sánh thay đổi, sao lưu tệp cũ vào `.backup/` (tự rollback nếu lỗi), giữ nguyên dữ liệu cục bộ (`accounts/`, `hub-config.json`, `oauth.local.clixml`) và yêu cầu xác nhận trước khi áp dụng và khởi động lại.

---

## Yêu cầu hệ thống

| Thành phần | Yêu cầu |
| --- | --- |
| Hệ điều hành | Windows (chạy cùng user Windows đang dùng Antigravity) |
| PowerShell | Windows PowerShell 5.1 (`%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`) |
| Antigravity Desktop | Bản 2.12 trở lên (hỗ trợ 2.34+), cài ở `%LOCALAPPDATA%\Programs\Antigravity` |
| Mạng | Truy cập dịch vụ Google OAuth/quota (và GitHub Releases khi kiểm tra cập nhật thủ công) |
| Node.js | *Không cần để chạy Hub*; chỉ cần khi chạy bộ kiểm thử (`tests\Validate.ps1`) |

---

## Cài đặt lần đầu

### 1. Tải mã nguồn về vị trí cố định

> Giữ nguyên thư mục repo sau khi cài vì shortcut Desktop và Startup sẽ trỏ cố định vào đường dẫn này.

```powershell
git clone https://github.com/7janv/antigravity-hub.git
cd antigravity-hub
```

### 2. Đăng nhập Antigravity Desktop
1. Mở **Antigravity Desktop** và đăng nhập tài khoản Google đầu tiên.
2. Hoàn tất các bước xác minh/điều khoản (nếu có) trong ứng dụng.

### 3. Chạy bộ cài đặt
Nhấp đúp **`Setup-Install.bat`** hoặc chạy trong PowerShell tại thư mục repo:

```powershell
.\Setup-Install.bat
```

Script cài đặt sẽ tự động:
1. Kiểm tra phiên bản Antigravity Desktop tương thích.
2. Tự dò và xác minh cấu hình OAuth cục bộ, mã hóa bằng **Windows DPAPI** kèm quyền NTFS chỉ cho user hiện tại vào `oauth.local.clixml`.
3. Tạo shortcut **Antigravity Auto-Hub** trên Desktop và **AntigravityAutoRotator** trong Windows Startup (trỏ trực tiếp `%SystemRoot%\System32\wscript.exe`).
4. Khởi chạy daemon chạy nền (quét mỗi **30 giây**) và mở giao diện Hub.

<details>
<summary>Tùy chọn nâng cao (ConfigureOnly / nhập OAuth thủ công)</summary>

- Chỉ cấu hình & xác minh OAuth (không tạo shortcut, không chạy daemon):
  ```powershell
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup.ps1 -ConfigureOnly
  ```
- Nhập Client ID / Client Secret OAuth thủ công (tự áp dụng DPAPI + quyền NTFS chỉ cho user hiện tại):
  ```powershell
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Configure-OAuth.ps1
  ```

</details>

---

## Sử dụng hằng ngày

1. Mở shortcut **Antigravity Auto-Hub** ngoài Desktop (hoặc chạy `Chuyen-Doi-Tai-Khoan.bat`).
2. **Thêm tài khoản vào pool xoay:**
   - **Cách khuyến nghị:** Đăng nhập tài khoản muốn lưu trong Antigravity Desktop → mở Hub bấm **Lưu acc hiện tại** → bấm **Quét quota**. Lặp lại cho các tài khoản khác.
   - **Hoặc:** Bấm **+ Thêm tài khoản** ngay trên Hub để đăng nhập qua trình duyệt.
3. **Cấu hình trong tab Cài đặt (Settings):**
   - Chọn giao diện **Light / AMOLED Dark**, bật/tắt **Tự động xoay**, **Tạm dừng quét khi đóng IDE** (khuyến nghị giữ bật), ngưỡng quota (10%–30%), cooldown (60s–300s) và kiểm tra bản phát hành mới từ GitHub Releases.
4. **Sẵn sàng xoay:** Cần ít nhất **2 tài khoản** hợp lệ, tài khoản dự phòng có đúng model đang chọn với quota cao hơn ngưỡng. Đóng cửa sổ Hub thu gọn xuống khay hệ thống; dùng menu khay hệ thống để thoát hẳn.

| Thao tác / Trạng thái | Ý nghĩa |
| --- | --- |
| **Quét quota** | Cập nhật ngay quota và gói cho toàn bộ tài khoản (dùng bộ đệm OAuth 30 phút) |
| **Chuyển** | Chuyển thủ công sang tài khoản đích (vẫn tuân thủ kiểm tra an toàn và cooldown) |
| **ⓘ (Chi tiết)** | Xem toàn bộ model API trả về, nhóm quota 5h / tuần và giờ reset theo giờ máy |
| **Xác minh** | Mở link xác minh Google (`https://accounts.google.com/signin/continue`) khi có `VALIDATION_REQUIRED` |

---

## Gỡ cài đặt (`Uninstall.ps1`)

Chạy script gỡ cài đặt từ thư mục repo:

```powershell
# Xem trước thao tác (không xóa thực tế)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall.ps1 -WhatIf

# Gỡ shortcut Desktop/Startup, dừng đúng daemon của thư mục này và dọn .backup/ (GIỮ NGUYÊN accounts/, hub-config.json, oauth.local.clixml)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall.ps1

# Gỡ cài đặt VÀ xóa toàn bộ dữ liệu người dùng cục bộ
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall.ps1 -PurgeData
```

---

## Quy trình đóng gói & phát hành (GitHub Releases)

1. Đẩy commit và gắn tag `vX.Y.Z` lên nhánh phát hành.
2. Workflow `.github/workflows/release.yml` trên GitHub Actions tự động chạy toàn bộ `tests\Validate.ps1`, đóng gói bằng `scripts\Build-Release.ps1` và phát hành GitHub Release gồm 3 tệp kiểm chứng:
   - `Antigravity-Auto-Hub-vX.Y.Z.zip`
   - `release-manifest.json` (liệt kê SHA-256 của từng tệp quản lý)
   - `SHA256SUMS.txt` (SHA-256 của tệp nén và manifest)

Đóng gói thử cục bộ:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build-Release.ps1 -Version v1.0.0
```

---

## Xử lý sự cố nhanh

| Hiện tượng | Cách khắc phục |
| --- | --- |
| **Báo `Chưa rõ quota` & khóa nút Chuyển** | Model đang chọn trên IDE chưa được cấp hoặc bị tắt (`disabled`) trên tài khoản đó. Bấm **ⓘ** để kiểm tra hoặc đổi model khác trong IDE |
| **Quota hiện `N/A`** | Chưa đọc được dữ liệu (lỗi mạng, hết hạn OAuth hoặc cần xác minh). Kiểm tra trạng thái trên thẻ và bấm **Quét quota** |
| **Quota thấp nhưng chưa tự xoay** | Kiểm tra xem IDE còn tác vụ đang chạy, còn bản nháp chưa gửi, đang bật tạm dừng xoay, đang trong cooldown hay không có acc dự phòng vượt ngưỡng |
| **Trạng thái `NeedsAttention` / `Switching` kéo dài** | Xem `rotator.log`, đóng/mở lại Antigravity nếu cần rồi bấm **Quét quota** hoặc chạy `.\AutoRotator.ps1 -Reconcile` |

---

## Kiểm thử & Cấu trúc mã nguồn

Chạy toàn bộ bộ kiểm thử tự động trên Windows (kiểm tra pure ASCII, chống BiDi/zero-width Unicode, cú pháp PowerShell, WPF XAML, kiểm thử bảo mật updater, OAuth, xoay tài khoản và MCP):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\tests\Validate.ps1
```

| File / Thư mục | Vai trò |
| --- | --- |
| `MainWindow.xaml`, `AntigravityHub.ps1` | Giao diện WPF, System Tray và khởi chạy ứng dụng |
| `Dashboard.ps1`, `DashboardText.vi.json` | Dữ liệu dashboard, quét nền, lọc/sắp xếp, Settings, theme và chuỗi tiếng Việt |
| `SafeUpdater.ps1` | Trình cập nhật an toàn từ GitHub Releases với kiểm chứng SHA-256 và cổng kiểm tra tĩnh |
| `ModelQuota.ps1` | Chuẩn hóa họ model, mức suy luận và nhóm quota |
| `AutoRotator.ps1`, `RotationCore.ps1` | Engine daemon (30s), bộ đệm OAuth 30 phút, mã hóa DPAPI `accounts/*.json` và xoay an toàn |
| `RuntimeBridge.ps1`, `AccountLogin.ps1` | Giao tiếp runtime/CDP (hỗ trợ 2.34+), kiểm tra rảnh/bản nháp và hỗ trợ đăng nhập |
| `Setup.ps1`, `OAuthSetup.ps1`, `Uninstall.ps1` | Cài đặt, tự dò/xác minh OAuth, tạo shortcut System32 và gỡ cài đặt an toàn |
| `AntigravityMcp.ps1`, `MCP.md` | Máy chủ MCP stdio đọc trạng thái và điều phối |
| `scripts/Build-Release.ps1`, `.github/workflows/release.yml` | Đóng gói bản phát hành có manifest và `SHA256SUMS.txt` cho GitHub Releases |
| `tests/` | Bộ kiểm thử giao diện, layout, model, xoay tài khoản, updater, setup và MCP |

> **Bảo mật:** Credential tài khoản (`accounts/*.json`, mã hóa DPAPI), cấu hình OAuth (`oauth.local.clixml`, mã hóa DPAPI), sao lưu `.backup/` và `.login-backup.dpapi` được lưu cục bộ với quyền NTFS chỉ dành cho user hiện tại và tự động loại trừ khỏi Git qua `.gitignore`. Không chia sẻ token, secret hay thư mục `accounts/` khi báo lỗi.

---

## Kho mã nguồn

- GitHub & Releases: [github.com/7janv/antigravity-hub](https://github.com/7janv/antigravity-hub)
