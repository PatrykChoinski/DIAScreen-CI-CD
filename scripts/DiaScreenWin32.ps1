<#
.SYNOPSIS
    Win32 helpers for driving DIAScreen (an MFC application) without a
    human: finding a process' windows and dialogs, sending ribbon commands
    (WM_COMMAND), filling/clicking dialog controls, reading the Output
    list (SysListView32, cross-process) and taking screenshots.
    Dot-source it: . "$PSScriptRoot\DiaScreenWin32.ps1"
#>

if (-not ("DiaWin32" -as [type])) {
    Add-Type -ReferencedAssemblies System.Drawing, System.Windows.Forms -TypeDefinition @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class DiaWin32 {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsHungAppWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr h, int id);
    [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, string l);
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();

    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint a, bool i, uint pid);
    [DllImport("kernel32.dll")] static extern IntPtr VirtualAllocEx(IntPtr p, IntPtr a, uint s, uint t, uint pr);
    [DllImport("kernel32.dll")] static extern bool VirtualFreeEx(IntPtr p, IntPtr a, uint s, uint t);
    [DllImport("kernel32.dll")] static extern bool WriteProcessMemory(IntPtr p, IntPtr a, byte[] b, uint s, out IntPtr w);
    [DllImport("kernel32.dll")] static extern bool ReadProcessMemory(IntPtr p, IntPtr a, byte[] b, uint s, out IntPtr r);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

    const uint WM_SETTEXT = 0x000C, WM_COMMAND = 0x0111, BM_CLICK = 0x00F5;

    public static string Text(IntPtr h) { var s = new StringBuilder(1024); GetWindowText(h, s, 1024); return s.ToString(); }
    public static string ClassOf(IntPtr h) { var s = new StringBuilder(256); GetClassName(h, s, 256); return s.ToString(); }

    // Visible top-level windows of a process.
    public static List<IntPtr> TopWindows(uint pid) {
        var r = new List<IntPtr>();
        EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p); if (p == pid && IsWindowVisible(h)) r.Add(h); return true; }, IntPtr.Zero);
        return r;
    }

    public static List<IntPtr> Children(IntPtr parent) {
        var r = new List<IntPtr>();
        EnumChildWindows(parent, (h, l) => { r.Add(h); return true; }, IntPtr.Zero);
        return r;
    }

    public static void Command(IntPtr frame, int id) { PostMessage(frame, WM_COMMAND, (IntPtr)id, IntPtr.Zero); }
    public static void SetText(IntPtr h, string text) { SendMessage(h, WM_SETTEXT, IntPtr.Zero, text); }
    public static void Click(IntPtr button) { PostMessage(button, BM_CLICK, IntPtr.Zero, IntPtr.Zero); }
    public static void PressEnter(IntPtr window) {
        PostMessage(window, 0x0100 /* WM_KEYDOWN */, (IntPtr)0x0D, (IntPtr)0x001C0001);
        PostMessage(window, 0x0101 /* WM_KEYUP */, (IntPtr)0x0D, unchecked((IntPtr)(int)0xC01C0001));
    }

    public static int ListViewCount(IntPtr lv) {
        return (int)SendMessage(lv, 0x1004 /* LVM_GETITEMCOUNT */, IntPtr.Zero, IntPtr.Zero);
    }

    // Rows [from, end) (column 0) of a SysListView32 owned by a 32-bit
    // process - DIAScreen is x86, so LVITEMW is laid out with 32-bit
    // pointers. Every row is a synchronous message to DIAScreen's UI
    // thread, so poll with a small window and read everything only once.
    public static List<string> ListViewRows(IntPtr lv, int from) {
        var res = new List<string>();
        uint pid; GetWindowThreadProcessId(lv, out pid);
        IntPtr hp = OpenProcess(0x0008 | 0x0010 | 0x0020 | 0x0400, false, pid);
        if (hp == IntPtr.Zero) return res;
        IntPtr mem = VirtualAllocEx(hp, IntPtr.Zero, 0x2000, 0x1000 | 0x2000, 0x04);
        try {
            int n = ListViewCount(lv);
            const int textOff = 0x100, cch = 1024;
            for (int i = Math.Max(0, from); i < n; i++) {
                var item = new byte[60];
                BitConverter.GetBytes(1u).CopyTo(item, 0);   // mask = LVIF_TEXT
                BitConverter.GetBytes(i).CopyTo(item, 4);    // iItem
                BitConverter.GetBytes(0).CopyTo(item, 8);    // iSubItem
                BitConverter.GetBytes((uint)(mem.ToInt64() + textOff)).CopyTo(item, 20); // pszText
                BitConverter.GetBytes(cch).CopyTo(item, 24); // cchTextMax
                IntPtr w;
                WriteProcessMemory(hp, mem, item, (uint)item.Length, out w);
                int len = (int)SendMessage(lv, 0x1073 /* LVM_GETITEMTEXTW */, (IntPtr)i, mem);
                var buf = new byte[cch * 2];
                ReadProcessMemory(hp, (IntPtr)(mem.ToInt64() + textOff), buf, (uint)buf.Length, out w);
                res.Add(Encoding.Unicode.GetString(buf, 0, Math.Max(0, Math.Min(len, cch)) * 2));
            }
        } finally {
            VirtualFreeEx(hp, mem, 0, 0x8000);
            CloseHandle(hp);
        }
        return res;
    }

    public static void Screenshot(string path) {
        try { SetProcessDPIAware(); } catch { }
        var b = System.Windows.Forms.SystemInformation.VirtualScreen;
        using (var bmp = new System.Drawing.Bitmap(b.Width, b.Height))
        using (var g = System.Drawing.Graphics.FromImage(bmp)) {
            g.CopyFromScreen(b.Left, b.Top, 0, 0, bmp.Size);
            bmp.Save(path, System.Drawing.Imaging.ImageFormat.Png);
        }
    }
}
"@
}

# Ribbon command IDs from DIAScreen.exe's ribbon resource (ID_COMPILE,
# ID_ONLINE_EMULATOR, ID_OFFLINE_EMULATOR).
$script:DiaCmd = @{
    Compile           = 50067
    OnlineSimulation  = 50070
    OfflineSimulation = 50071
}

function Get-DialogDescription {
    # "Title: static text 1 | static text 2 [buttons: OK, Cancel]" - enough
    # to tell from a CI log what a dialog wanted.
    param([IntPtr]$Hwnd)
    $texts = New-Object System.Collections.Generic.List[string]
    $buttons = New-Object System.Collections.Generic.List[string]
    foreach ($c in [DiaWin32]::Children($Hwnd)) {
        $t = [DiaWin32]::Text($c)
        if (-not $t) { continue }
        switch -Regex ([DiaWin32]::ClassOf($c)) {
            '^Button$' { $buttons.Add($t) }
            '^(Static|Edit|RichEdit.*)$' { $texts.Add(($t -replace '\s+', ' ').Trim()) }
        }
    }
    "'{0}': {1} [buttons: {2}]" -f [DiaWin32]::Text($Hwnd), ($texts -join ' | '), ($buttons -join ', ')
}

function Get-ProcessDialogs {
    # Visible standard dialogs (#32770) of a process - message boxes and
    # modal dialogs like "Disable Protection".
    param([int]$ProcessId)
    @([DiaWin32]::TopWindows($ProcessId) | Where-Object { [DiaWin32]::ClassOf($_) -eq '#32770' })
}

function Invoke-UiaButton {
    # Press a button by name in a window that has no Win32 child controls
    # (Qt dialogs) through UI Automation; falls back to Enter, which
    # triggers the dialog's default button. Returns $true when invoked.
    param([IntPtr]$Window, [string]$Name)
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    $AE = [System.Windows.Automation.AutomationElement]
    try {
        $root = $AE::FromHandle($Window)
        $cond = New-Object System.Windows.Automation.AndCondition(
            (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)),
            (New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, $Name)))
        $btn = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
        if ($btn) {
            $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
            return $true
        }
    } catch { }
    [DiaWin32]::PressEnter($Window)
    return $false
}

function Find-DialogButton {
    param([IntPtr]$Dialog, [string[]]$Captions)
    foreach ($c in [DiaWin32]::Children($Dialog)) {
        if ([DiaWin32]::ClassOf($c) -ne 'Button') { continue }
        $t = ([DiaWin32]::Text($c) -replace '&', '').Trim()
        if ($Captions -contains $t) { return $c }
    }
    return [IntPtr]::Zero
}
