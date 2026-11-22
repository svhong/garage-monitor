import QtQuick
import org.kde.kirigami as Kirigami
import "logic.js" as Logic

// Draws one or more series as lines. series: [{ values, min, max, color, fill }]
Canvas {
    id: spark
    property var series: []
    renderStrategy: Canvas.Cooperative

    onSeriesChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()

    onPaint: {
        var ctx = getContext("2d");
        ctx.reset();
        var w = width, h = height, pad = 2;

        // faint baseline grid at 25/50/75%
        ctx.strokeStyle = Logic.css(Kirigami.Theme.textColor, 0.07);
        ctx.lineWidth = 1;
        for (var gi = 1; gi < 4; gi++) {
            var gy = Math.round(h * gi / 4) + 0.5;
            ctx.beginPath(); ctx.moveTo(0, gy); ctx.lineTo(w, gy); ctx.stroke();
        }

        (series || []).forEach(function (s) {
            var vals = s.values || [];
            if (vals.length < 2) return;
            var step = w / (vals.length - 1);
            var y = function (v) {
                var c = Math.min(s.max, Math.max(s.min, v));
                return (h - pad) - (c - s.min) / (s.max - s.min) * (h - 2 * pad);
            };
            // Split into runs so gaps (nulls) aren't bridged.
            var runs = [], cur = [];
            for (var i = 0; i < vals.length; i++) {
                if (typeof vals[i] === "number" && isFinite(vals[i])) cur.push([i * step, y(vals[i])]);
                else if (cur.length) { runs.push(cur); cur = []; }
            }
            if (cur.length) runs.push(cur);

            runs.forEach(function (pts) {
                if (pts.length < 2) return;
                if (s.fill) {
                    ctx.fillStyle = Logic.css(s.color, 0.15);
                    ctx.beginPath();
                    ctx.moveTo(pts[0][0], h);
                    pts.forEach(function (p) { ctx.lineTo(p[0], p[1]); });
                    ctx.lineTo(pts[pts.length - 1][0], h);
                    ctx.closePath();
                    ctx.fill();
                }
                ctx.strokeStyle = Logic.css(s.color, 1);
                ctx.lineWidth = 1.5;
                ctx.lineJoin = "round";
                ctx.beginPath();
                ctx.moveTo(pts[0][0], pts[0][1]);
                for (var k = 1; k < pts.length; k++) ctx.lineTo(pts[k][0], pts[k][1]);
                ctx.stroke();
            });
        });
    }
}
