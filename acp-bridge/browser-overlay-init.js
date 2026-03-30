/**
 * Fazm Browser Overlay — Init Script
 *
 * Auto-injected by Playwright MCP via --init-script flag.
 * Shows an animated glowing overlay indicating the browser is controlled by Fazm.
 * Persists across all page navigations automatically.
 */
(function injectFazmOverlay() {
  console.log('[fazm-overlay] injectFazmOverlay called, existing:', !!document.getElementById('fazm-overlay'));
  if (document.getElementById('fazm-overlay')) return;

  var overlay = document.createElement('div');
  overlay.id = 'fazm-overlay';
  overlay.innerHTML = '<style>'
    + '#fazm-canvas2{position:fixed;inset:0;z-index:2147483647;pointer-events:none;overflow:hidden}'
    + '.fazm-wing{position:absolute;pointer-events:none}'
    + '#fazm-w-top{top:0;left:-20%;right:-20%;height:55%;background:radial-gradient(ellipse 140% 100% at 50% -10%,rgba(147,51,234,.45) 0%,rgba(99,102,241,.3) 20%,rgba(59,130,246,.18) 40%,rgba(6,182,212,.08) 60%,transparent 80%);animation:fazm-pulse-top 4s ease-in-out infinite}'
    + '#fazm-w-bottom{bottom:0;left:-20%;right:-20%;height:55%;background:radial-gradient(ellipse 140% 100% at 50% 110%,rgba(147,51,234,.4) 0%,rgba(6,182,212,.25) 20%,rgba(59,130,246,.15) 40%,rgba(139,92,246,.06) 60%,transparent 80%);animation:fazm-pulse-bottom 4s ease-in-out infinite 1s}'
    + '#fazm-w-left{left:0;top:-20%;bottom:-20%;width:50%;background:radial-gradient(ellipse 100% 140% at -10% 50%,rgba(139,92,246,.4) 0%,rgba(99,102,241,.25) 20%,rgba(59,130,246,.12) 45%,transparent 75%);animation:fazm-pulse-left 5s ease-in-out infinite .5s}'
    + '#fazm-w-right{right:0;top:-20%;bottom:-20%;width:50%;background:radial-gradient(ellipse 100% 140% at 110% 50%,rgba(139,92,246,.4) 0%,rgba(6,182,212,.25) 20%,rgba(59,130,246,.12) 45%,transparent 75%);animation:fazm-pulse-right 5s ease-in-out infinite 1.5s}'
    + '.fazm-blob{position:absolute;border-radius:50%;filter:blur(60px);opacity:.6}'
    + '#fazm-blob1{width:40vw;height:40vh;top:-5%;left:-5%;background:rgba(168,85,247,.35);animation:fazm-float1 6s ease-in-out infinite}'
    + '#fazm-blob2{width:35vw;height:35vh;top:-5%;right:-5%;background:rgba(6,182,212,.3);animation:fazm-float2 7s ease-in-out infinite 1s}'
    + '#fazm-blob3{width:40vw;height:40vh;bottom:-5%;left:-5%;background:rgba(59,130,246,.3);animation:fazm-float3 8s ease-in-out infinite 2s}'
    + '#fazm-blob4{width:35vw;height:35vh;bottom:-5%;right:-5%;background:rgba(168,85,247,.3);animation:fazm-float4 6.5s ease-in-out infinite .5s}'
    + '@keyframes fazm-pulse-top{0%,100%{transform:scaleY(.85) translateY(-5%);opacity:.7}50%{transform:scaleY(1.15) translateY(5%);opacity:1}}'
    + '@keyframes fazm-pulse-bottom{0%,100%{transform:scaleY(.85) translateY(5%);opacity:.7}50%{transform:scaleY(1.15) translateY(-5%);opacity:1}}'
    + '@keyframes fazm-pulse-left{0%,100%{transform:scaleX(.8) translateX(-5%);opacity:.6}50%{transform:scaleX(1.2) translateX(5%);opacity:1}}'
    + '@keyframes fazm-pulse-right{0%,100%{transform:scaleX(.8) translateX(5%);opacity:.6}50%{transform:scaleX(1.2) translateX(-5%);opacity:1}}'
    + '@keyframes fazm-float1{0%,100%{transform:translate(-10%,-10%) scale(1)}33%{transform:translate(15%,10%) scale(1.3)}66%{transform:translate(5%,20%) scale(.9)}}'
    + '@keyframes fazm-float2{0%,100%{transform:translate(10%,-10%) scale(1.1)}33%{transform:translate(-10%,15%) scale(.8)}66%{transform:translate(-5%,5%) scale(1.2)}}'
    + '@keyframes fazm-float3{0%,100%{transform:translate(-10%,10%) scale(.9)}33%{transform:translate(10%,-10%) scale(1.2)}66%{transform:translate(20%,-5%) scale(1)}}'
    + '@keyframes fazm-float4{0%,100%{transform:translate(10%,10%) scale(1)}33%{transform:translate(-15%,-10%) scale(1.1)}66%{transform:translate(-5%,-15%) scale(.85)}}'
    + '@keyframes fazm-spin3{to{transform:rotate(360deg)}}'
    + '#fazm-pill3{position:fixed!important;top:50%!important;left:50%!important;transform:translate(-50%,-50%)!important;z-index:2147483647!important;pointer-events:none!important;display:flex!important;align-items:center!important;gap:8px!important;padding:5px 16px!important;background:rgba(0,0,0,.2)!important;border-radius:12px!important;border:1px solid rgba(147,51,234,.15)!important;font-family:-apple-system,BlinkMacSystemFont,sans-serif!important;font-size:12px!important;color:rgba(0,0,0,.5)!important;font-weight:600!important;backdrop-filter:blur(8px)!important;box-shadow:none!important;white-space:nowrap!important;max-height:28px!important;height:28px!important;line-height:1!important;overflow:hidden!important}'
    + '#fazm-pill3 .fazm-sp3{width:10px!important;height:10px!important;border:1.5px solid rgba(147,51,234,.15)!important;border-top-color:rgba(168,85,247,.4)!important;border-radius:50%!important;animation:fazm-spin3 1s linear infinite!important;flex-shrink:0!important}'
    + '</style>'
    + '<div id="fazm-canvas2">'
    + '<div class="fazm-wing" id="fazm-w-top"></div>'
    + '<div class="fazm-wing" id="fazm-w-bottom"></div>'
    + '<div class="fazm-wing" id="fazm-w-left"></div>'
    + '<div class="fazm-wing" id="fazm-w-right"></div>'
    + '<div class="fazm-blob" id="fazm-blob1"></div>'
    + '<div class="fazm-blob" id="fazm-blob2"></div>'
    + '<div class="fazm-blob" id="fazm-blob3"></div>'
    + '<div class="fazm-blob" id="fazm-blob4"></div>'
    + '</div>'
    + '<div id="fazm-pill3">'
    + '<div class="fazm-sp3"></div>'
    + '<span>Browser controlled by Fazm \u00b7 Feel free to switch tabs or use other apps</span>'
    + '</div>';

  if (document.documentElement) {
    document.documentElement.appendChild(overlay);
  } else {
    document.addEventListener('DOMContentLoaded', function() {
      document.documentElement.appendChild(overlay);
    });
  }
})();
