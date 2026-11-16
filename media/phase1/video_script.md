# Phase 1 video script

## 1. Gokul VKS (about 55 s)

> Hi, I'm Gokul VKS, the team lead.\
> Neural networks spend most of their time multiplying matrices.\
> Our project is a hardware accelerator for that: a systolic array, written in Verilog.\
> I'm here with Milind Bansal, Isha Tomar, Yashi Agrawal and Mohammad Affan Anas.
>
> Here's how it works.\
> The host writes two signed 8-bit matrices, A and B, and sends a start pulse.\
> Then a four-by-four grid of processing elements works on them in parallel: up to sixteen multiply-accumulates per clock cycle.\
> A controller runs each step, and an output buffer holds the result for the host to read.
>
> I wrote the specification first, so all five of us could build in parallel.\
> Then I built the processing-element grid and the top level.

## 2. Yashi Agrawal (about 47 s)

> Hi, I'm Yashi Agrawal. I did the literature review and the golden model.\
> Systolic arrays were introduced by H. T. Kung and Charles Leiserson in 1979.\
> Each number is read from memory once, then reused as it moves from cell to cell.\
> That matters, because reading off-chip memory costs over a thousand times more energy than an 8-bit multiply.\
> Google's Tensor Processing Unit is built on the same idea.
>
> To check our hardware, I wrote a golden model in Python.\
> It generates 106 test cases: six hand-picked edge cases and 100 random ones.\
> The hardware has to match every single one.

## 3. Milind Bansal (about 47 s)

> Hi, I'm Milind Bansal. I built the processing element and the controller.\
> Each processing element multiplies two signed 8-bit numbers, and adds the product to a 32-bit accumulator, every cycle.\
> One cycle later, it passes A to the right and B downward.\
> The accumulator can't overflow: the largest possible sum needs only 18 of its 32 bits.\
> Here's one processing element in simulation: one times five, plus two times six, plus three times seven, plus four times eight, gives 70.
>
> The controller is a five-state machine: idle, clear, compute, capture and done.\
> For a four-by-four array, compute lasts exactly ten cycles.

## 4. Isha Tomar (about 45 s)

> Hi, I'm Isha Tomar. I built the input and output buffers, and the end-to-end test.\
> The key to a systolic array is timing.\
> A moves right and B moves down, but row i of A starts i cycles late, and column j of B starts j cycles late.\
> So the two numbers that belong together always meet at the right processing element, in the same cycle.\
> My skew buffers create those delays, and the output buffer holds the result for reading.
>
> Then I tested the whole accelerator on all 106 golden cases.\
> Every element of every result matches.

## 5. Mohammad Affan Anas (about 43 s)

> Hi, I'm Mohammad Affan Anas. I set up our tools and the automated testing.\
> Everything we use is free and open source: Icarus Verilog to simulate, Verilator to lint, GTKWave for waveforms, and Python for the golden model.\
> My setup guide installs it all on macOS, Linux or Windows.
>
> One command, make lint test, checks every hardware module and runs all seven testbenches.\
> GitHub runs the same command on every pull request, so a broken change is caught before it's merged.\
> I also drew the project's architecture diagrams, from editable source files.

## 6. Gokul VKS (about 45 s)

> So, does it work? Yes.\
> All seven testbenches pass: more than ten thousand checks, and zero failures.\
> The specification predicted 12 cycles from start to done: one to clear, ten to compute and one to capture.\
> The hardware takes exactly 12, in every run.
>
> A four-by-four product needs 64 multiply-accumulates.\
> One multiplier on its own would need 64 cycles. Our array needs 10.\
> That's 6.4 times faster, or 5.3 times counting all 12 cycles.
>
> In Phase 2, we'll synthesize the design, build that one-multiplier baseline in hardware, and widen the input and output ports.\
> Thanks for watching.
