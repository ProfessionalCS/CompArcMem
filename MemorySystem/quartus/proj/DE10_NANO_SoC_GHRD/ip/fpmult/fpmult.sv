`timescale 1ns / 1ps

// Control Signals:
// start: from <input> to main control FSM (start FP multiplication)
// Mdone: from multiplier control FSM to main control FSM (indicates when fraction multiplication is done)
// Fnorm: from fraction multiplier data path to main control FSM (indicates when fraction is normalized)
// EV: from exponent adder to main control FSM (indicates when exponent overflow)
// Load: from main control FSM to fraction multiplier and exponent adder (load fractions into multiplier, exponents into exponent adder, sign bits into signCompute)
// Adx: from main control FSM to multiplier control FSM and exponent adder (signal to add exponents, start fraction multiplier)
// RSF: from main control FSM to fraction multiplier (signal to right shift fraction)
// Inc: from main control FSM to exponent adder (signal to increment exponent)
// LSF: from main control FSM to fraction multiplier (signal to left shift fraction)
// Dec: from main control FSM to exponent adder (signal to decrement exponent)
// done: from main control FSM to <output> (indicates when multiplication is complete)
// err: from main control FSM to <output> (indicates when there is an error such as overflow or underflow)
// M: from fraction multiplier data path to multiplier control FSM (current LSB of multiplier)
// Sh: from multiplier control FSM to fraction multiplier (perform shift only)
// AdSh: from multiplier control FSM to fraction multiplier (perform shift and add)


module fpmult #(parameter int P = 8, parameter int Q = 8) (
  input logic rst_in_N, // synchronous active-low reset
  input logic clk_in, // clock
  input logic [P+Q-1:0] x_in, // input X; x_in[P+Q-1] is the sign bit
  input logic [P+Q-1:0] y_in, // input Y: y_in[P+Q-1] is the sign bit
  input logic [1:0] round_in, // rounding mode specifier
  input logic start_in, // signal to start multiplication
  output logic [P+Q-1:0] p_out, // output P: p_out[P+Q-1] is the sign bit
  output logic [3:0] oor_out, // out-of-range indicator vector
  output logic valid_out, // the outputs are valid
  output logic ready_out // the FPM is ready to receive new inputs
);

  // Internal signals
  logic Sx, Sy; // sign bits of x and y
  logic [P-1:0] Fx, Fy; // fraction bits of x and y (including hidden 1)
  logic [Q-1:0] Ex, Ey; // exponent bits of x and y
  logic S; // sign bit of the product
  logic [P-1:0] F; // fraction bits of the product (including hidden 1)
  logic [Q-1:0] E; // exponent bits of the product
  logic Mdone; // signal from multiplier control FSM indicating multiplication is done
  // logic Fnorm; // signal from fraction multiplier data path indicating fraction is normalized
  // logic EV; // signal from exponent adder indicating exponent overflow
  logic Load; // signal to load fractions into multiplier and exponents into exponent adder
  logic Adx; // signal to start fraction multiplication and exponent addition
  // logic RSF; // signal to right shift fraction
  logic Inc; // signal to increment exponent
  // logic LSF; // signal to left shift fraction
  logic Dec; // signal to decrement exponent
  logic done; // signal indicating multiplication is complete
  logic err; // signal indicating an error such as overflow or underflow

  // Signals for overflow and normalization and errors
  logic Fnorm, FV, FZ; // Norm, overflow, and zero flags from the fraction multiplier
  logic RSF, LSF;
  logic EV;

  // Instantiate submodules
  InputHandler #(P, Q) inputHandler (
    .rstInN(rst_in_N),
    .clkIn(clk_in),
    .Load(Load),
    .xIn(x_in),
    .yIn(y_in),
    .SxOut(Sx),
    .FxOut(Fx),
    .ExOut(Ex),
    .SyOut(Sy),
    .FyOut(Fy),
    .EyOut(Ey)
  );

  SignCompute signCompute (
    .rstInN(rst_in_N),
    .clkIn(clk_in),
    .Sx(Sx),
    .Sy(Sy),
    .S(S)
  );

  // Multiplier outputs 2*P-1 bits, needs to be reduced to P bits (including hidden 1)
  logic [2*P-1:0] _P; // Unnormalized product from multiplier (2*P bits)
  topmult #(P) multiplier (
    .clk(clk_in),
    .rst(rst_in_N),
    .start(Adx), // Start signal from main control FSM
    .RSF(RSF),
    .LSF(LSF),
    .A(Fx), // Fraction of X (including hidden 1)
    .B(Fy), // Fraction of Y (including hidden 1)
    .done(Mdone), // Done signal to main control FSM
    .fnorm(Fnorm),
    .fv(FV),
    .fz(FZ),
    .product(_P) // Product of fractions to be used in assembler
  );

  ExponentAdder #(P, Q) exponentAdder (
    .rstInN(rst_in_N),
    .clkIn(clk_in),
    .adx(Adx),
    .inc(Inc),
    .dec(Dec),
    .Ex(Ex),
    .Ey(Ey),
    .E(E),
    .EV(EV)
  );

  logic latchOut = 0;
  MainControlFSM #(P, Q) mainControlFSM (
    .rstInN(rst_in_N),
    .clkIn(clk_in),
    .startIn(start_in),
    .Mdone(Mdone),
    .Fnorm(Fnorm),
    .EV(EV),
    .Load(Load),
    .Adx(Adx),
    .RSF(RSF),
    .Inc(Inc),
    .LSF(LSF),
    .Dec(Dec),
    .doneOut(done),
    .errOut(err),
    .latchOut(latchOut),
    .FV(FV),
    .FZ(FZ)
  );

  Assembler #(P, Q) assembler (
    .rstInN(rst_in_N),
    .clkIn(clk_in),
    .latch(latchOut),
    .oor(oor_out),
    .S(S),
    .F(F),
    .E(E),
    .p(p_out)
  );

  // The product is 2*P bits wide. After normalization, extract the top P bits.
  assign F = _P[2*P-2:P-1];

  logic x_is_inf, y_is_inf;
  logic x_is_zero, y_is_zero;

  always_ff @(posedge clk_in) begin
    if (!rst_in_N) begin
      x_is_zero <= 0;
      y_is_zero <= 0;
      x_is_inf <= 0;
      y_is_inf <= 0;
    end 
    else if (Load) begin
      // Exponent and fraction is all 0s (not sure if signed bit can be 1)
      x_is_zero <= (x_in[P+Q-2:0] == 0);
      y_is_zero <= (y_in[P+Q-2:0] == 0);
      // Exponent is all 1s and fraction is all 0s
      x_is_inf <= (x_in[P+Q-2:P-1] == {P{1'b1}}) && (x_in[Q-2:0] == 0);
      y_is_inf <= (y_in[P+Q-2:P-1] == {P{1'b1}}) && (y_in[Q-2:0] == 0);
    end
  end

  // Output logic (note from the lab assignment)
  // oor_out[3] is the zero flag, which indicates whether the output p_out is 0
  // oor_out[2] is the infinity flag, which indicates whether the output p_out is infinity
  // oor_out[1] is the NaN flag, which indicates whether the output p_out is NaN
  // oor_out[0] is the subnormal flag, which indicates whether the output p_out is a subnormal number
  // Always set oor_out to 4'b0000 if p_out is a normalized number
  always_comb begin
    oor_out = 4'b0000;
    if (x_is_inf || y_is_inf) oor_out[2] = 1;
    else if (x_is_zero || y_is_zero || FZ) oor_out[3] = 1;
  end

  assign valid_out = done;
  assign ready_out = (done || !start_in);
endmodule : fpmult

module MainControlFSM #(parameter int P = 8, parameter int Q = 8) (
  input logic rstInN,
  input logic clkIn,
  input logic startIn,
  input logic Mdone, // from multiplier control FSM
  input logic Fnorm, // from fraction multiplier data path
  input logic EV, // from exponent adder
  input logic FV,
  input logic FZ,
  output logic Load, // to fraction multiplier and exponent adder
  output logic Adx, // to multiplier control FSM and exponent adder
  output logic RSF, // to fraction multiplier
  output logic Inc, // to exponent adder
  output logic LSF, // to fraction multiplier
  output logic Dec, // to exponent adder
  output logic doneOut, // to <output>
  output logic errOut, // to <output>
  output logic latchOut
);

  // States
  localparam S0 = 3'b000; // Idle state
  localparam S1 = 3'b001; // Load and start
  localparam S2 = 3'b010; // Wait for multiply
  localparam S3 = 3'b011; // Normalization
  localparam S4 = 3'b100; // Latch values (After staying on normalization)
  localparam S5 = 3'b101; // Done

  reg [2:0] currState, nextState;

  // Synchronous (current state)
  always_ff @(posedge clkIn) begin
    if (!rstInN) begin
      // State control
      currState <= S0;
    end
    else begin
      currState <= nextState;
    end 
  end

  // Asynch (next state computation)
  always_comb begin
    nextState = currState;

    Load = 0; 
    Adx = 0;
    LSF = 0; 
    RSF = 0; 
    Inc = 0; 
    Dec = 0;
    doneOut = 0;
    latchOut = 0;
    errOut = 0;

    case (currState)
      S0: begin
        if (startIn) begin
          Load = 1;
          nextState = S1;
        end
      end

      S1: begin // Load regs and start exponent add and fraction mult
        Adx = 1; // Start mult
        nextState = S2; 
      end

      S2: begin
        // Wait for multiplier, then check if normalization needed (but that will be for next state)
        if (Mdone) begin
          nextState = S3;
        end
      end

      S3: begin
        // Normalization state 
        // Shift as needed until normalized
        if (FV) begin
            // Fraction overflow, shift right just one
            RSF = 1; 
            Inc = 1;
            nextState = S4;
        end
        else if (!Fnorm && !FZ) begin // If nor normalized and not zero
          // Shift left and decrement
          LSF = 1;
          Dec = 1;
          nextState = S3; // Loop
        end
        else begin
          // Normalized or Zero
          nextState = S4;
        end
      end

      S4: begin
        // Latch output before DONE signal (some weird stablizing issues, before the clk changes states)
        latchOut = 1;
        nextState = S5;
      end

      S5: begin
        doneOut = 1;
        if (EV) errOut = 1;
        
        // Wait until next start signal (current start signal has to drop)
        // If starts early, jump to 1 (kind of skipped what was supposed to happen in the FSM on the slides)
        if (startIn) begin
          // Load = 1;			// Bypassing the original code we submitted
          // nextState = S1;		// Bypassing the original code we submitted
          nextState = S5;		// Wait until we drop the start signal to 0
        end
        else begin
          nextState = S0;
        end
      end

      default: nextState = S0;
    endcase
  end
endmodule : MainControlFSM

// Takes in Ex and Ey, outputs E with a bias 127 (E = Ex + Ey - bias)
module ExponentAdder #(parameter int P = 8, parameter int Q = 8) (
  input logic rstInN,
  input logic clkIn,
  input logic adx, // Add exponents
  input logic inc, // Increment exponent
  input logic dec, // Decrement exponent
  input logic [Q-1:0] Ex, // exponent of X
  input logic [Q-1:0] Ey, // exponent of Y
  output logic [Q-1:0] E, // output exponent (after addition and bias adjustment)
  output logic EV
);
  logic signed [Q+1:0] sum; // Signed for overflow detection

  always_ff @(posedge clkIn) begin
    if (!rstInN) begin
      E <= 0;
      EV <= 0;
    end
    // Add and return exponents
    else if (adx)  begin  
      // Handle zeros
      // If we have zeros, then the exponent should ONLY be 1s
      logic [Q-1:0] tempEx, tempEy; 
      if (Ex == 0) begin
        tempEx = 1;
      end
      else begin
        tempEx = Ex;
      end
      if (Ey == 0) begin
        tempEy = 1;
      end
      else begin
        tempEy = Ey;
      end
      sum = $signed({2'b0, tempEx}) + $signed({2'b0, tempEy}) - 127; // 127 is bias for FP16, value is buffer for checking the additional bits
      
      if (sum >= ((2**Q) - 2)) begin  // Check for overflow (max is 254 for Q=8)
        E <= (2**Q) - 2;
        EV <= 1;
      end
      else if (sum < 0) begin  // Check for underflow
        E <= 0;
        EV <= 0;  // Underflow doesn't have error message though
      end
      else begin
        E <= sum[Q-1:0];
        EV <= 0;
      end
    end
    // Check overflow on increment
    else if (inc) begin
      if (E >= ((2**Q) - 2)) begin // If exponent is greater than 254
        E <= (2**Q) - 2; // Then cap the output value to max exponent vs. infinity?
        EV <= 1;
      end
      else begin
        E <= E + 1;
      end
    end
    // Check underflow on decrement (negatives)
    else if (dec) begin
      if (E == 0) begin
        E <= 0;
      end
      else begin
        E <= E - 1;
      end
    end
  end
endmodule : ExponentAdder

// Computers the sign using Sx and Sy, outputs S as S = Sx ^ Sy
module SignCompute (
  input logic rstInN,
  input logic clkIn,
  input logic Sx, // sign bit of X
  input logic Sy, // sign bit of Y
  output logic S // output sign bit
);
  always_ff @(posedge clkIn) begin
    if (!rstInN) begin
      S <= 0; // reset sign to 0 on reset
    end else begin
      S <= Sx ^ Sy; // compute sign as XOR of Sx and Sy
    end
  end
endmodule : SignCompute

// Assembles S, E, and F into output p
// Also handles special cases if they exist
module Assembler #(parameter int P = 8, parameter int Q = 8) (
  input logic rstInN,
  input logic clkIn,
  input logic latch,
  input logic [3:0] oor, // Based on errors
  input logic S, // sign bit of the product
  input logic [P-1:0] F, // fraction bits of the product (plus hidden 1)
  input logic [Q-1:0] E, // exponent bits of the product
  output logic [P+Q-1:0] p // output product in the same format as x_in and y_in
);
  always_ff @(posedge clkIn) begin
    if (!rstInN) begin
      p <= 0; // reset output to 0 on reset
    end
    else if (latch) begin  // Only latch when done signal is asserted
      // Zeros - Set exponent and fraction to 0, preserve sign
      if (oor[3]) begin
        p <= {S, {(P+Q-1){1'b0}}};
      // Infinities - Set exponent to all 1s, fraction to 0, preserve sign
      end
      else if (oor[2]) begin
        p <= {S, {Q{1'b1}}, {(P-1){1'b0}}}; 
      end
      // Normal case
      else begin
        p <= {S, E, F[P-2:0]}; // concatenate S, E, and F (remove hidden one) to form the output  
      end

      // p <= {S, E, F[P-2:0]}; // concatenate S, E, and F (remove hidden one) to form the output  
    end
  end
endmodule : Assembler

// Takes in x and y, outputs Sx, Fx, Ex, Sy, Fy, Ey
module InputHandler #(parameter int P = 8, parameter int Q = 8) (
  input logic rstInN,
  input logic clkIn,
  input logic Load,
  input logic [P+Q-1:0] xIn, // input X; xIn[P+Q-1] is the sign bit
  input logic [P+Q-1:0] yIn, // input Y: yIn[P+Q-1] is the sign bit
  output logic SxOut, // sign bit of X
  output logic [P-1:0] FxOut, // fraction bits of X (plus hidden 1)
  output logic [Q-1:0] ExOut, // exponent bits of X
  output logic SyOut, // sign bit of Y
  output logic [P-1:0] FyOut, // fraction bits of Y (plus hidden 1)
  output logic [Q-1:0] EyOut // exponent bits of Y
);
  always_ff @(posedge clkIn) begin
    if (!rstInN) begin
      SxOut <= 0;
      FxOut <= 0;
      ExOut <= 0;
      SyOut <= 0;
      FyOut <= 0;
      EyOut <= 0;
    end else if (Load) begin
      SxOut <= xIn[P+Q-1]; // extract sign bit of X
      ExOut <= xIn[P+Q-2:Q-1]; // extract exponent bits of X
      // ExOut <= xIn[P-1 +: Q]; // extract exponent bits of X
      SyOut <= yIn[P+Q-1]; // extract sign bit of Y
      EyOut <= yIn[P+Q-2:Q-1]; // extract exponent bits of Y
      // EyOut <= yIn[P-1 +: Q]; // extract exponent bits of Y
      
      // Only add hidden bit for non-zero exponents
      if (xIn[P+Q-2:P-1] == 0) begin
        FxOut <= {1'b0, xIn[P-2:0]}; // Zero, hidden bit not needed
      end else begin
        FxOut <= {1'b1, xIn[P-2:0]}; // Normalm add hidden 1
      end
      
      if (yIn[P+Q-2:P-1] == 0) begin
        FyOut <= {1'b0, yIn[P-2:0]}; // Zero, hidden bit not needed
      end else begin
        FyOut <= {1'b1, yIn[P-2:0]}; // Normal, add hidden 1
      end
    end
  end
endmodule : InputHandler

/*
 *
 * FRACTION MULTIPLIER MODULES
 * 
 */

module topmult #(parameter P = 8) (
	// Input signals
	input logic clk,
	input logic rst,
	input logic start,
	input logic RSF,    // For normalization purposes
	input logic LSF,    // For normalization purposes

	// Input values
	input logic [P-1:0] A, // multiplier, includes hidden 1
	input logic [P-1:0] B, // multiplicand, includes hidden 1 

	// Output signals
	output logic done,
	output logic fnorm, // Fraction is normalized
	output logic fv,    // Other flags to possibly look at (overflow)
	output logic fz,    // Zero flag
	
	// Output values
	output logic [2*P-1:0] product
);

	wire load, ad, sh, m;
	reg [2*P:0] raw_product;

	shiftaddmult #(.N(P)) multiplier (
		.clk(clk), 
		.rst(rst),
		.load(load), 
		.sh(sh), 
		.ad(ad),
		.RSF(RSF),
		.LSF(LSF),
		.multiplier(A), // 8 bits, 1 hidden
		.multiplicand(B), // 8 bits, 1 hidden
		.m(m),
		.product(raw_product) // 17 bits
	);

	multcontroller #(.N(P)) controller (
		.clk(clk), 
		.rst(rst),
		.start(start),
		.m(m),
		.load(load), 
		.sh(sh), 
		.ad(ad),
		.done(done)
	);

	// Normalization logic for fraction multiplier 
	assign fnorm = raw_product[2*P-2]; // "MSB" of the actual product (feed to the main controller)

	// Additional flags for errors
	assign fv = raw_product[2*P-1]; // Overflow
	assign fz = (raw_product == 0); // Zero flag

	assign product = raw_product[2*P-1:0];
endmodule

// Parameter N is the size of the multiplicand, multiplier, and N-bit adder
module shiftaddmult #(parameter int N = 8) (
	// Input signals
	input logic clk,
	input logic rst,
	input logic load,
	input logic sh,     // Shift
	input logic ad,     // Add
	input logic RSF,
	input logic LSF,

	// Input values
	input logic [N-1:0] multiplier,
	input logic [N-1:0] multiplicand,
	
	// Output signals
	output logic m,     // LSB of multiplier

	// Output values
	output logic [2*N:0] product // Raw product value (1 additional bit in the carry out)
);
	reg [2*N:0] accumulate;             // Acc reg for intermediate mult calculations
	// reg [N-1:0] temp_multiplicand = {N{1'b0}};

	// N-bit combinational logic adder (in FP16, 4-bit adder)
	wire [N:0] adder_res;
	// assign adder_res = accumulate[2*N-1:N] + temp_multiplicand;
	assign adder_res = accumulate[2*N-1:N] + multiplicand;

	logic [2*N:0] acc_update;
	
	// Rest of data path flow (synchronous)
	always_ff @(posedge clk) begin : shiftadd
		if (!rst) begin
			accumulate = 0;
			 // temp_multiplicand <= 0;
		end
		else begin
			if (load) begin
				// Initialize
				// Note: Data from the adder should not be ready to clk in until the next cycle.
				//       Have the accumulate reg cleared for upper n bits.
				accumulate <= { {N+1{1'b0}}, multiplier };
				// temp_multiplicand <= multiplicand;
			end
			else if (RSF) begin // Normalization
				acc_update = accumulate;
				accumulate = acc_update >> 1;
			end
			else if (LSF) begin // Normalization
				acc_update = accumulate;
				accumulate = acc_update << 1;
			end
			else begin
				// Add-Shift logic

				if (ad) begin
					// Note: Carry out from the adder is implicitly already a part of adder_res
					acc_update = {adder_res, accumulate[N-1:0]};
				end
				else begin
					acc_update = accumulate;
				end

				if (sh) begin
					accumulate = acc_update >> 1;
				end
				else begin
					accumulate = acc_update;
				end    
			end
		end
	end

	// Assign outputs
	assign m = accumulate[0];
	assign product = accumulate[2*N:0];
endmodule

// Parameter N is the number of bits that need to be multiplied
module multcontroller #(parameter int N = 8) (
	// Input signals
	input logic clk,
	input logic rst,
	input logic start,  // Also the Adx signal

	// Input values
	input logic m,      // LSB of the multiplier

	// Output signals
	output logic load,
	output logic ad,     // ad
	output logic sh,     // sh
	output logic done
);
	// Find how many bits to store for the counter (between repetitive shift or shift/ add states)
	localparam STATE_CNT = $clog2(N);
	logic [STATE_CNT-1:0] current_count, next_count;

	// Note: Localparam serves as constant (kind of like a macro to define each state) 
	localparam S0 = 1'b0;   // Either Idle
	localparam S1 = 1'b1;   // or looping certain states

	reg current_state, next_state;

	// Assign state (synchronous)
	always_ff @(posedge clk) begin
		if (!rst) begin
			current_state <= S0;
			current_count <= 0;
		end
		else begin
			current_state <= next_state;
			current_count <= next_count;
		end 
	end

	// Next state logic (asynchronous)
	always_comb begin
		// Assuming default state that nothing happens
		load = 0;
		sh = 0;
		ad  = 0;
		done = 0;
		next_state = current_state;
		next_count = current_count;

		case (current_state)
			S0: begin
				if (start) begin    // Adx is "start" signal
					load = 1;
					next_state = S1;
					next_count = 0;
				end 
				else begin
					next_state = S0;
				end
			end

			S1: begin
				if (m) begin
					ad = 1;         // If M=1, then ad
				end
				sh = 1;             // Always sh

				// If we're not on the last loop, keep iterating and looping shift or shift/ add
				// We're on last loop if count is equal to second to last bit
				if (current_count == STATE_CNT'(N-1)) begin
					// Note: Needs to perform one last sh or sh/ ad before marking as done.
					//       But then again, the current state will be set to done so that main control
					//       clocks the done signal on the next cycle (so setting done is for next clk edge).
					next_state = S0;    // Return to Idle
					done = 1;           // Assert Done
				end
				else begin
					next_state = S1;    // Loop
					next_count = current_count + 1;
				end
			end
			
			default: next_state = S0;

		endcase
	end
endmodule
