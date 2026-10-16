// SPDX-License-Identifier: GPL-3.0-or-later
//
// Unsigned restoring divider, one quotient bit a clock: q = n / d, NW clocks
// after start. d = 0 gives q = all ones (the callers never use it).

module dj_div #(
    parameter int NW = 24,
    parameter int DW = 16
) (
    input                 clk,
    input                 start,
    input      [NW-1:0]   n,
    input      [DW-1:0]   d,
    output reg [NW-1:0]   q,
    output reg            busy = 1'b0
);

reg [NW-1:0] nr;
reg [DW:0]   r;
reg [$clog2(NW+1)-1:0] k;
wire [DW:0] r2 = { r[DW-1:0], nr[NW-1] };
reg  [DW-1:0] dr;

always @(posedge clk) begin
    if (start) begin
        nr <= n; dr <= d; r <= '0; q <= '0; k <= NW[$clog2(NW+1)-1:0]; busy <= 1'b1;
    end else if (busy) begin
        nr <= { nr[NW-2:0], 1'b0 };
        if (r2 >= { 1'b0, dr }) begin r <= r2 - { 1'b0, dr }; q <= { q[NW-2:0], 1'b1 }; end
        else                    begin r <= r2;                q <= { q[NW-2:0], 1'b0 }; end
        k <= k - 1'd1;
        if (k == 1) busy <= 1'b0;
    end
end

endmodule
