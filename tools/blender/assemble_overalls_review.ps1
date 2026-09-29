Add-Type -AssemblyName System.Drawing
$shotDir = Join-Path $PSScriptRoot 'preview/overalls'
$clips = @('Idle','Run','Jump','Dive','Slip','Nice','Come','ComeHip','ComeCool','SlideEnter','SlideSit','SlideReverseFall','SlideProne','SlideRecover','RespawnDizzy')
$font = [System.Drawing.Font]::new('Arial',12)
for ($page=0; $page -lt 3; $page++) {
 $canvas = [System.Drawing.Bitmap]::new(960,1800)
 $g = [System.Drawing.Graphics]::FromImage($canvas)
 $g.Clear([System.Drawing.Color]::White)
 for ($row=0; $row -lt 5; $row++) {
  $clip = $clips[$page*5+$row]
  for ($step=0; $step -lt 3; $step++) {
   $im = [System.Drawing.Image]::FromFile((Join-Path $shotDir "pose_${clip}_${step}.png"))
   $g.DrawImage($im,$step*320,$row*360+20,320,340)
   $g.DrawString("$clip / $step",$font,[System.Drawing.Brushes]::Black,$step*320+5,$row*360)
   $im.Dispose()
  }
 }
 $canvas.Save((Join-Path $shotDir "pose_audit_${page}.png"))
 $g.Dispose();$canvas.Dispose()
}
$font.Dispose()
