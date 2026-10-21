# --- コンソールを隠す設定 ---
# 実行時に表示されるPowerShellの黒いウィンドウ（コンソール）を非表示にします。
Add-Type -Name Window -Namespace Win32 -MemberDefinition @"
[DllImport("user32.dll")]
public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("kernel32.dll")]
public static extern IntPtr GetConsoleWindow();
"@
$consolePtr = [Win32.Window]::GetConsoleWindow()
[void][Win32.Window]::ShowWindow($consolePtr, 0) # 0 = 非表示(SW_HIDE)

# --- 設定項目１ ---
$filePrefix  = "ActionLog*" # 監視するファイル名のパターン
# ----------------

# --- 設定項目２ (config.ini から読み込む) ---
# EXEとして実行した場合はEXEの場所、.ps1として実行した場合はスクリプトの場所でconfig.iniを探します
if ($MyInvocation.MyCommand.CommandType -eq "ExternalScript") {
    $currentDir = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
} else {
    $currentDir = Split-Path -Parent -Path ([Environment]::GetCommandLineArgs()[0])
}
$configPath = Join-Path $currentDir "config.ini"

# デフォルト値
$watchFolder = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "SEGA\PHANTASYSTARONLINE2\log_ngs"
$fontType = "Meiryo"
$fontSize = 8
$formSize_X = 640
$formSize_y = 480

if (Test-Path $configPath) {
    try {
        $iniContent = Get-Content $configPath -Encoding UTF8
        foreach ($line in $iniContent) {
            $trimmedLine = $line.Trim()
            # 「=」が含まれており、かつ「[」で始まらない行（セクション名無視）だけを処理
            if ($trimmedLine -match "=" -and -not $trimmedLine.StartsWith("[")) {
                $pair = $trimmedLine.Split("=", 2)
                if ($pair.Count -eq 2) {
                    $key = $pair[0].Trim()
                    $val = $pair[1].Trim()

                    switch ($key) {
                        "LogPath"    { $watchFolder = $val }
                        "FontType"   { $fontType = $val.Trim() }
                        "FontSize"   { $fontSize = [int]$val }
                        "FormSize_X" { $formSize_X = [int]$val }
                        "FormSize_Y" { $formSize_Y = [int]$val }
                        Default {
                            
                        }
                    }
                }
            }
        }
    } catch {
        # ここでエラーが起きても一切画面に出さず、デフォルト値で進む
    }
}
# ---------------------------------------

# --- 状態管理用変数 ---
$script:lastFilePath = ""    # 現在監視しているログファイルのフルパス
$script:ignoreList   = @{}   # 起動時に既に存在していた行を「無視する行」として記録するリスト
# ----------------------

# Windows フォーム（画面）の基本設定
Add-Type -AssemblyName System.Windows.Forms
$form = New-Object Windows.Forms.Form
$form.Text = "PSO2NGS_取得アイテム集計Ver1.010"
$form.Size = New-Object Drawing.Size($formSize_X, $formSize_Y)
$form.TopMost = $true # 常に最前面に表示（ゲーム画面等に隠れないようにする）

# 集計結果を表示するためのテキストボックス設定
$textBox = New-Object Windows.Forms.TextBox
$textBox.Multiline = $true    # 複数行の表示を許可
$textBox.Dock = "Fill"       # ウィンドウ全体のサイズに広げる
$textBox.ScrollBars = "Both"  # 必要に応じて縦横のスクロールバーを表示
$textBox.ReadOnly = $true     # ユーザーによる書き換えを禁止
$textBox.Font = New-Object Drawing.Font($fontType, $fontSize)

# --- ★ここから追加：Ctrl+A (全選択) を有効にする設定 ---
$textBox.Add_KeyDown({
    param($sender, $e)
    # Ctrlキー と Aキー が同時に押された場合
    if ($e.Control -and ($e.KeyCode -eq [Windows.Forms.Keys]::A)) {
        $sender.SelectAll()   # すべて選択
        $e.SuppressKeyPress = $true # 標準の「ポーン」という警告音を鳴らさない
    }
})
# ---------------------------------------------------

$form.Controls.Add($textBox)

# 指定フォルダ内で最も更新日時が新しいログファイルを特定する関数
function Get-LatestFile {
    if (-not (Test-Path $watchFolder)) { return $null }
    Get-ChildItem -Path $watchFolder -Filter $filePrefix | 
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

# 起動した瞬間のログ内容をスキャンし、既存の行をすべて「無視リスト」に登録する関数
function Initialize-Baseline {
    $latest = Get-LatestFile
    if ($null -eq $latest) { return }
    $script:lastFilePath = $latest.FullName
    $script:ignoreList = @{}

    try {
        # 他のプロセスが書き込み中でも読み取れる（SharedReadモード）でファイルを開く
        $stream = [System.IO.File]::Open($latest.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $reader = New-Object System.IO.StreamReader($stream)
        while (($line = $reader.ReadLine()) -ne $null) {
            # 同じ内容の行がある場合も考慮し、行をキーにして出現回数をカウント
            [void]($script:ignoreList[$line]++)
        }
        $reader.Close(); $stream.Close()
    } catch { }
    
    $res = "新規ドロップを待機中...`r`n(監視対象: $($watchFolder))"
#    $res += "`r`n$configPath    `r`n$fontType`r`n$fontSize`r`n$formSize_X`r`n$formSize_Y"
    $textBox.Text = $res
}

# ログファイルをスキャンして新しいドロップを集計・表示するメイン関数
function Update-Display {
    $latest = Get-LatestFile
    if ($null -eq $latest) { return }

    # 日付が変わるなどで新しいログファイルが生成された場合、無視リストをリセットして最初から読む
    if ($latest.FullName -ne $script:lastFilePath) {
        $script:ignoreList = @{}
        $script:lastFilePath = $latest.FullName
    }

    try {
        # ファイル全体を読み込む
        $stream = [System.IO.File]::Open($latest.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $reader = New-Object System.IO.StreamReader($stream)
        
        $inventory = @{} # 今回の集計結果を格納する配列
        $currentIgnore = $script:ignoreList.Clone() # 無視リストをコピーして、1行ずつ消費しながらスキャンする

        while (($line = $reader.ReadLine()) -ne $null) {
            # 起動時に存在していた行（無視リスト内）であれば、集計せずにスキップ
            if ($currentIgnore.ContainsKey($line) -and $currentIgnore[$line] -gt 0) {
                $currentIgnore[$line]--
                continue
            }

            # --- ここから「起動後に追加された新しい行」の解析 ---
            # 大文字小文字を厳密に区別して [Pickup] 行を特定
            if ($line -cmatch "\[Pickup\]") {
                $cols = $line.Split("`t") # タブで分割
                if ($cols.Count -ge 7) {
                    $itemCol = $cols[$cols.Count - 2].Trim() # 右から2番目：アイテム名/メセタ名
                    $numCol  = $cols[$cols.Count - 1].Trim() # 一番右：個数/所持金合計

                    $name = ""; $amt = 0
                    # メセタ判定：右から2番目にメセタ記述がある場合のみ。末尾の所持金合計(Current...)は無視。
                    if ($itemCol -match "N-Meseta\((\d+)\)") {
                        $name = "メセタ"; $amt = [int]$Matches[1]
                    } 
                    # 通常アイテム判定：一番右に Num(数字) がある場合。
                    elseif ($numCol -match "Num\((\d+)\)") {
                        $name = $itemCol; $amt = [int]$Matches[1]
                    }

                    # 特定アイテム（レスタサイン等）は除外
                    if ($name -eq "RestaSign" -or $name -eq "ReverserSign") { continue }
                    # 有効なデータであれば集計に加算
                    if ($name -ne "" -and $amt -gt 0) { $inventory[$name] += $amt }
                }
            }
        }
        $reader.Close(); $stream.Close()

        # 画面への整形表示
        if ($inventory.Count -gt 0) {
            $res = "【取得アイテム】"
            foreach ($key in ($inventory.Keys | Sort-Object { $inventory[$_] } -Descending)) {
                if ($key -eq "メセタ") { 
                    $res += "{0,12:N0} {1}`r`n" -f $inventory[$key], $key 
                }
            }
            $res += "  数量 : アイテム名`r`n------------------------------------------`r`n"
            # 数量が多い順にソートして表示
            foreach ($key in ($inventory.Keys | Sort-Object { $inventory[$_] } -Descending)) {
                if ($key -ne "メセタ") { 
                    $res += "{0,6} : {1}`r`n" -f $inventory[$key], $key 
                }
            }
            $textBox.Text = $res
        }
    } catch {
        # ファイルアクセス競合等が発生した場合は、次回の更新タイミングで再試行
    }
}

# 2秒ごとに自動更新を行うタイマーの設定
$timer = New-Object System.Windows.Forms.Timer -Property @{ Interval = 2000 }
$timer.Add_Tick({ Update-Display })

# 画面が表示された時の初期化処理
$form.Add_Shown({
    Initialize-Baseline # 起動時点のログを無視リストに登録
    $timer.Start()      # 監視タイマー開始
})

# ウィンドウが閉じられる時の終了処理
$form.Add_FormClosing({
    $timer.Stop()
    Stop-Process -Id $PID # 自分自身のPowerShellプロセスを確実に終了させる
})

# アプリケーションの実行（ウィンドウの表示）
$form.ShowDialog()