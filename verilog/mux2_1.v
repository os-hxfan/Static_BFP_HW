// __module info begin__
// name     : mux2_1
// function : mux, choose 1 output from 2 inputs
// __module info end__

module mux2_1
(
  input           up_dat0,
  input           up_dat1,
  input           sel,
  output          dn_dat
); // fifo

assign dn_dat=(sel)?up_dat1:up_dat0;

endmodule // fifo