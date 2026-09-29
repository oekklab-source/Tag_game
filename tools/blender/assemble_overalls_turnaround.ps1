Add-Type -AssemblyName System.Drawing
$shotDir = Join-Path $PSScriptRoot 'preview/overalls'
$reviewDir = Join-Path $PSScriptRoot 'references/overalls_review'
New-Item -ItemType Directory -Force $reviewDir | Out-Null
$names = @('front','front_three','side','back_three','back','back_other','side_other','front_other','top','bottom')
$font = [System.Drawing.Font]::new('Arial',15)
$sheet = [System.Drawing.Bitmap]::new(1600,744)
$g = [System.Drawing.Graphics]::FromImage($sheet)
$g.Clear([System.Drawing.Color]::White)
for ($i=0; $i -lt $names.Count; $i++) {
 $x=($i%5)*320; $y=[math]::Floor($i/5)*372
 $im=[System.Drawing.Image]::FromFile((Join-Path $shotDir ("godot_"+$names[$i]+'.png')))
 $g.DrawImage($im,[int]$x,[int]($y+30),320,340)
 $g.DrawString($names[$i],$font,[System.Drawing.Brushes]::Black,[int]($x+6),[int]$y)
 $im.Dispose()
}
$sheet.Save((Join-Path $reviewDir 'godot_turnaround.png'))
$g.Dispose();$sheet.Dispose()
# Consistent side-by-side framing, preserve original rendered pixels and backgrounds.
$reference=[System.Drawing.Image]::FromFile((Join-Path $PSScriptRoot 'references/overalls_turnaround_v1.png'))
$rects=@(@(125,108,240,279),@(845,110,235,279),@(124,443,239,274))
$views=@('front','side','back')
$canvas=[System.Drawing.Bitmap]::new(1536,370)
$g=[System.Drawing.Graphics]::FromImage($canvas);$g.Clear([System.Drawing.Color]::White)
for ($i=0; $i -lt 3; $i++) {
 $r=$rects[$i];$src=[System.Drawing.Rectangle]::new($r[0],$r[1],$r[2],$r[3])
 $dst=[System.Drawing.Rectangle]::new($i*512,35,256,320)
 $g.DrawImage($reference,$dst,$src,[System.Drawing.GraphicsUnit]::Pixel)
 $g.DrawString("Reference / "+$views[$i],$font,[System.Drawing.Brushes]::Black,$i*512+4,4)
 $im=[System.Drawing.Image]::FromFile((Join-Path $shotDir ("godot_"+$views[$i]+'.png')))
 $src=[System.Drawing.Rectangle]::new(75,74,490,560)
 $dst=[System.Drawing.Rectangle]::new($i*512+256,35,256,320)
 $g.DrawImage($im,$dst,$src,[System.Drawing.GraphicsUnit]::Pixel)
 $g.DrawString('Godot model',$font,[System.Drawing.Brushes]::Black,$i*512+260,4)
 $im.Dispose()
}
$canvas.Save((Join-Path $reviewDir 'reference_comparison.png'))
$g.Dispose();$canvas.Dispose();$reference.Dispose();$font.Dispose()
