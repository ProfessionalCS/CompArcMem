`timescale 1ns/1ps

module llcdTb;
	logic clk;
	logic rstN;



	llcd (
		.clk(clk),
		.rstN(rstN),

		.l1ReqValid(),
		.l1ReqWrite(),
		.l1Addr(),
		.l1DataIn(),
		.l1DataOut(),
		.l1RespValid(),

		.memReadReqReady(),
		.memReadRespValid(),
		.memWriteReqReady(),
		.memDataIn(),
		.memAddr(),
		.memDataOut(),
		.memReadReqValid(),
		.memReadRespReady(),
		.memWriteReqValid()
	);

endmodule: llcdTb