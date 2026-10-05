`timescale 1ns / 1ps
//
// Full-chip testbench: top_tangnano20k + sdram_model, driven through the
// real SPI pins by a bit-banged SPI master that honours BUSY like the
// Arduino library does.
//
// Modes (plusargs):
//   +selftest            PING, STATUS, FILL_RECT + READ_RECT readback,
//                        RESET; prints PASS/FAIL
//   +cmds=<file>         replay a recorded command stream (tools/golden):
//                        per transaction "<n> <b0> ... <bn-1>" in hex
//   +dump=<file>         after replay, wait for the engine to go idle and
//                        dump framebuffer +buf=<0|1> (default 0) as one
//                        native RGB565 value (4 hex digits) per line,
//                        row-major 320x240
//
// Simulation clocks: `define SIMULATION makes clocks.v pass clk27 through
// as both the system and the pixel clock (64.8MHz here), which is fine
// functionally - the two scanout domains are still crossed through the
// same synchronisers.
//
module tb_top;
  reg clk = 0;
  always #7.716 clk = ~clk;

  reg btn_s1 = 1'b0, btn_s2 = 1'b0;
  wire [5:0] led_n;
  wire tcp, tcn;
  wire [2:0] tdp, tdn;
  reg  sck = 0, mosi = 0, cs_n = 1;
  wire miso, busy;

  wire [31:0] DQ;
  wire [10:0] A;
  wire [1:0]  BA;
  wire nCS, nWE, nRAS, nCAS, SCLK, CKE;
  wire [3:0] DQM;

  top_tangnano20k #(.SIM_INIT_US(2)) dut (
      .clk27(clk), .btn_s1(btn_s1), .btn_s2(btn_s2), .led_n(led_n),
      .tmds_clk_p(tcp), .tmds_clk_n(tcn), .tmds_d_p(tdp), .tmds_d_n(tdn),
      .spi_sck(sck), .spi_mosi(mosi), .spi_miso(miso), .spi_cs_n(cs_n),
      .gpu_busy(busy),
      .IO_sdram_dq(DQ), .O_sdram_addr(A), .O_sdram_ba(BA), .O_sdram_cs_n(nCS),
      .O_sdram_wen_n(nWE), .O_sdram_ras_n(nRAS), .O_sdram_cas_n(nCAS),
      .O_sdram_clk(SCLK), .O_sdram_cke(CKE), .O_sdram_dqm(DQM)
  );

  sdram_model #(.CAS(2)) mem (
      .SDRAM_DQ(DQ), .SDRAM_A(A), .SDRAM_BA(BA), .SDRAM_nCS(nCS),
      .SDRAM_nWE(nWE), .SDRAM_nRAS(nRAS), .SDRAM_nCAS(nCAS),
      .SDRAM_CLK(SCLK), .SDRAM_CKE(CKE), .SDRAM_DQM(DQM)
  );

  // ---------------- SPI master ----------------
  // SCK half period in system clocks (+sckhalf=<n>, default 3 = ~10.8MHz;
  // 2 = ~16.2MHz, the fastest write clock the oversampling slave supports)
  real HALF = 7.716 * 2 * 3;
  integer sck_half_cycles;
  // read transactions: +readhalf=<n> system clocks per half period
  // (default 4x the write half period)
  real RHALF = 7.716 * 2 * 12;
  integer read_half_cycles;
  initial begin
    if ($value$plusargs("sckhalf=%d", sck_half_cycles)) begin
      HALF = 7.716 * 2 * sck_half_cycles;
      RHALF = HALF * 4;
    end
    if ($value$plusargs("readhalf=%d", read_half_cycles)) RHALF = 7.716 * 2 * read_half_cycles;
  end

  reg [7:0] rx;
  task spi_byte(input [7:0] tx);
    integer b;
    begin
      for (b = 7; b >= 0; b = b - 1) begin
        mosi = tx[b];
        #(HALF);
        sck = 1;
        rx[b] = miso;
        #(HALF);
        sck = 0;
      end
    end
  endtask

  // slower clock for transactions that read MISO
  task spi_byte_slow(input [7:0] tx);
    integer b;
    begin
      for (b = 7; b >= 0; b = b - 1) begin
        mosi = tx[b];
        #(RHALF);
        sck = 1;
        rx[b] = miso;
        #(RHALF);
        sck = 0;
      end
    end
  endtask

  task cs_begin; begin #(HALF); cs_n = 0; #(HALF); end endtask
  task cs_end;   begin #(HALF); cs_n = 1; #(HALF * 4); end endtask

  task wait_not_busy;
    integer t;
    begin
      t = 0;
      while (busy) begin
        @(posedge clk);
        t = t + 1;
        if (t == 2_000_000) begin
          $display("FAIL: BUSY stuck - engine state %0d op %h b_req %b fifo used %0d",
                   dut.u_exec.state, dut.u_exec.op, dut.u_exec.b_req, dut.cmd_used);
          $finish;
        end
      end
    end
  endtask

  integer errors = 0;
  reg [7:0] resp [0:4095];

  // engine activity, for performance figures (printed after a replay)
  integer busy_cycles = 0;
  always @(posedge clk) if (!dut.exec_idle || dut.cmd_valid) busy_cycles = busy_cycles + 1;

  // generic read transaction: [0][op] then n response bytes into resp[]
  task read_txn(input [7:0] op, input integer n);
    integer k;
    begin
      cs_begin;
      spi_byte_slow(8'h00);
      spi_byte_slow(op);
      for (k = 0; k < n; k = k + 1) begin
        spi_byte_slow(8'h00);
        resp[k] = rx;
      end
      cs_end;
    end
  endtask

  task wait_idle;
    integer quiet, t;
    begin
      quiet = 0;
      t = 0;
      while (quiet < 200) begin
        @(posedge clk);
        t = t + 1;
        if (t == 20_000_000) begin
          $display("FAIL: engine never idle - state %0d op %h cx %0d cy %0d",
                   dut.u_exec.state, dut.u_exec.op, dut.u_exec.cx, dut.u_exec.cy);
          $finish;
        end
        if (dut.exec_idle && !dut.cmd_valid && !dut.cmd_push) quiet = quiet + 1;
        else quiet = 0;
      end
    end
  endtask

  // ---------------- replay ----------------
  // Replays a recorded transaction file. Lines: "<n> <b0> ... <bn-1>" (hex).
  // PING/STATUS polls are skipped (no side effects, the engine is simply
  // allowed to finish instead). A READ_DATA transaction is executed once
  // the engine is idle, and must be followed by an expected-response line
  // "fffffff <m> <bytes>" (from the emulator) that the RTL has to match.
  reg [7:0] txn [0:262143];
  task replay(input [8*256-1:0] fname);
    integer fd, n, m, k, v, r, count, reads;
    begin
      fd = $fopen(fname, "r");
      if (fd == 0) begin
        $display("FAIL: cannot open %0s", fname);
        $finish;
      end
      count = 0;
      reads = 0;
      while (!$feof(fd)) begin
        r = $fscanf(fd, "%h", n);
        if (r == 1) begin
          for (k = 0; k < n; k = k + 1) begin
            r = $fscanf(fd, "%h", v);
            txn[k] = v[7:0];
          end
          if (n >= 2 && (txn[1] == 8'h01 || txn[1] == 8'h03)) begin
            // poll: skip
          end else if (n >= 2 && txn[1] == 8'h51) begin
            wait_idle;
            read_txn(8'h51, n - 2);
            r = $fscanf(fd, "%h", v);
            if (v != 32'hfffffff) begin
              $display("FAIL: READ_DATA without expected-response line");
              $finish;
            end
            r = $fscanf(fd, "%h", m);
            for (k = 0; k < m; k = k + 1) begin
              r = $fscanf(fd, "%h", v);
              if (resp[k] !== v[7:0]) begin
                if (errors < 10)
                  $display("FAIL: readback %0d byte %0d: RTL %h, expected %h", reads, k, resp[k], v[7:0]);
                errors = errors + 1;
              end
            end
            reads = reads + 1;
          end else begin
            cs_begin;
            for (k = 0; k < n; k = k + 1) begin
              if (k % 64 == 0) wait_not_busy;
              spi_byte(txn[k]);
            end
            cs_end;
          end
          count = count + 1;
          if (count % 100 == 0)
            $display("%0t ns: %0d transactions, engine state %0d, op %h, fifo used %0d",
                     $time / 1000, count, dut.u_exec.state, dut.u_exec.op, dut.cmd_used);
        end
      end
      $fclose(fd);
      $display("replayed %0d transactions (%0d readbacks checked)", count, reads);
    end
  endtask

  task dump_fb(input [8*256-1:0] fname, input integer bsel);
    integer fd, x, y;
    reg [31:0] w;
    begin
      fd = $fopen(fname, "w");
      for (y = 0; y < 240; y = y + 1)
        for (x = 0; x < 320; x = x + 1) begin
          w = mem.mem[{2'b00, 3'b000, bsel[0], y[7:0], x[8:1]}];
          $fwrite(fd, "%04h\n", x[0] ? w[31:16] : w[15:0]);
        end
      $fclose(fd);
    end
  endtask

  // ---------------- self test ----------------
  task selftest;
    integer k;
    begin
      // PING
      read_txn(8'h01, 5);
      if (resp[0] != "T" || resp[1] != "A" || resp[2] != "N" || resp[3] != "G" || resp[4] != 8'h01) begin
        $display("FAIL ping: %h %h %h %h %h", resp[0], resp[1], resp[2], resp[3], resp[4]);
        errors = errors + 1;
      end
      // wrong address must be ignored (MISO tri-stated -> reads as z/x, engine untouched)
      cs_begin; spi_byte(8'h05); spi_byte(8'h20); spi_byte(8'h00); cs_end;

      // STATUS: sdram ready, not busy, cmd_free = 4095
      read_txn(8'h03, 7);
      if (!(resp[2] & 8'h10) || (resp[2] & 8'h01) || {resp[1], resp[0]} != 16'd4095) begin
        $display("FAIL status: free=%0d flags=%b", {resp[1], resp[0]}, resp[2]);
        errors = errors + 1;
      end

      // FILL_RECT (10,20) 7x3 colour F800 (red), then READ_RECT (9,19) 9x5
      cs_begin;
      spi_byte(8'h00); spi_byte(8'h20);
      spi_byte(8'd10); spi_byte(8'd0); spi_byte(8'd20); spi_byte(8'd0);
      spi_byte(8'd7);  spi_byte(8'd0); spi_byte(8'd3);  spi_byte(8'd0);
      spi_byte(8'hf8); spi_byte(8'h00);
      cs_end;
      cs_begin;
      spi_byte(8'h00); spi_byte(8'h50);
      spi_byte(8'd9); spi_byte(8'd0); spi_byte(8'd19); spi_byte(8'd0);
      spi_byte(8'd9); spi_byte(8'd0); spi_byte(8'd5);  spi_byte(8'd0);
      cs_end;
      wait_idle;
      read_txn(8'h03, 7);
      if ({resp[6], resp[5]} != 16'd90) begin
        $display("FAIL resp_used=%0d (expected 90)", {resp[6], resp[5]});
        errors = errors + 1;
      end
      read_txn(8'h51, 90);
      $display("readback row 20: %h%h %h%h %h%h ... %h%h %h%h", resp[18], resp[19], resp[20], resp[21],
               resp[22], resp[23], resp[32], resp[33], resp[34], resp[35]);
      for (k = 0; k < 45; k = k + 1) begin
        // pixel (9 + k%9, 19 + k/9): red inside [10..16]x[20..22]
        if (((k % 9) >= 1 && (k % 9) <= 7 && (k / 9) >= 1 && (k / 9) <= 3) ?
            ({resp[2*k], resp[2*k+1]} != 16'hf800) : ({resp[2*k], resp[2*k+1]} != 16'h0000)) begin
          $display("FAIL readback pixel %0d,%0d = %h", 9 + k % 9, 19 + k / 9, {resp[2*k], resp[2*k+1]});
          errors = errors + 1;
        end
      end

      // unknown opcode -> bad_opcode flag, RESET clears it
      cs_begin; spi_byte(8'h00); spi_byte(8'h7f); cs_end;
      wait_idle;
      read_txn(8'h03, 7);
      if (!(resp[2] & 8'h08)) begin $display("FAIL: bad opcode not flagged"); errors = errors + 1; end
      cs_begin; spi_byte(8'h00); spi_byte(8'h02); cs_end;
      repeat (20) @(posedge clk);
      read_txn(8'h03, 7);
      if (resp[2] & 8'h08) begin $display("FAIL: RESET did not clear bad opcode"); errors = errors + 1; end

      if (mem.errors != 0) begin $display("FAIL: %0d SDRAM protocol errors", mem.errors); errors = errors + mem.errors; end
      if (errors == 0) $display("PASS tb_top selftest");
      else             $display("FAIL tb_top selftest: %0d errors", errors);
    end
  endtask

  reg [8*256-1:0] cmds_file, dump_file;
  integer buf_sel;
  integer x, y;

  initial begin
    // SDRAM contents start as zero (black) like after a real clear
    for (y = 0; y < 512; y = y + 1)
      for (x = 0; x < 256; x = x + 1)
        mem.mem[{2'b00, 3'b000, y[8:0], x[7:0]}] = 32'd0;

    btn_s1 = 1;
    repeat (20) @(posedge clk);
    btn_s1 = 0;
    while (!dut.sdram_ready) @(posedge clk);
    repeat (300) @(posedge clk);   // past the reset counter

    if ($test$plusargs("selftest")) selftest;

    if ($value$plusargs("cmds=%s", cmds_file)) begin
      replay(cmds_file);
      wait_idle;
      read_txn(8'h03, 7);
      if (resp[2] & 8'h4c) begin
        $display("FAIL: flags=%b (overflow / bad opcode / scanout late)", resp[2]);
        errors = errors + 1;
      end
      if (mem.errors != 0) begin $display("FAIL: %0d SDRAM protocol errors", mem.errors); errors = errors + 1; end
      if (!$value$plusargs("buf=%d", buf_sel)) buf_sel = 0;
      if ($value$plusargs("dump=%s", dump_file)) dump_fb(dump_file, buf_sel);
      $display("engine busy for %0d cycles (%0d us at 64.8MHz)", busy_cycles, busy_cycles * 10 / 648);
      if (errors == 0) $display("PASS tb_top replay");
    end
    $finish;
  end

  initial begin
    #2_000_000_000;
    $display("FAIL tb_top: timeout");
    $finish;
  end
endmodule
