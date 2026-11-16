"""Golden reference model for the systolic-array accelerator (issue #14).

Two independent models of C = A x B, both following docs/spec.md:

* ``matmul`` is the plain mathematical reference. Every expected value in the
  test vectors comes from it.
* ``simulate_output_stationary`` steps an N x N output-stationary array one
  cycle at a time, with the same input skew and forwarding registers as the
  RTL (spec sections 6.2 to 6.4 and 7.1). It is a second opinion on the
  timing contract: it must agree with ``matmul`` after exactly
  T = K + 2N - 2 steps.

``edge_inputs`` reproduces table 7.2 (what the skew buffers drive on each
lane in each step), so testbenches and waveform readers can check lanes
against it.
"""

import numpy as np

DATA_W = 8
ACC_W = 32


def signed_range(width):
    """Smallest and largest value of a ``width``-bit two's complement number."""
    return -(1 << (width - 1)), (1 << (width - 1)) - 1


def compute_cycles(n, k=None):
    """Compute cycles T = K + 2N - 2 (spec section 7.1)."""
    k = n if k is None else k
    return k + 2 * n - 2


def busy_cycles(n, k=None):
    """Cycles with busy high, start to done: T + 2 = K + 2N (spec 7.4)."""
    return compute_cycles(n, k) + 2


def check_operand(matrix, data_w=DATA_W, name="operand"):
    """Return ``matrix`` as an int64 array, or raise if any value does not fit
    in ``data_w`` signed bits. Catching this here keeps a bad vector from
    reaching the RTL, where it would silently be truncated."""
    m = np.asarray(matrix)
    if m.ndim != 2:
        raise ValueError(f"{name} must be a 2-D matrix, got shape {m.shape}")
    if not np.issubdtype(m.dtype, np.integer):
        raise TypeError(f"{name} must hold integers, got {m.dtype}")
    m = m.astype(np.int64)
    lo, hi = signed_range(data_w)
    if m.size and (m.min() < lo or m.max() > hi):
        raise ValueError(
            f"{name} has values outside [{lo}, {hi}] for DATA_W = {data_w}")
    return m


def check_result(c, acc_w=ACC_W):
    """Raise if any element of C overflows ``acc_w`` signed bits. The RTL does
    not saturate (spec section 4), so an overflow would be a spec violation,
    not a rounding difference."""
    lo, hi = signed_range(acc_w)
    if c.size and (c.min() < lo or c.max() > hi):
        raise OverflowError(f"result does not fit in ACC_W = {acc_w} bits")
    return c


def matmul(a, b, data_w=DATA_W, acc_w=ACC_W):
    """Reference C = A x B for signed ``data_w``-bit operands, as int64.

    The product is formed in int64, which is wide enough that NumPy cannot
    wrap silently; the result is then checked against ``acc_w``.
    """
    a = check_operand(a, data_w, "A")
    b = check_operand(b, data_w, "B")
    if a.shape[1] != b.shape[0]:
        raise ValueError(f"inner dimensions differ: A is {a.shape}, B is {b.shape}")
    return check_result(a @ b, acc_w)


def edge_inputs(a, b, t):
    """Values on ``a_left`` and ``b_top`` in compute step ``t`` (table 7.2).

    Lane i of a_left carries A[i][t - i] and lane j of b_top carries
    B[t - j][j] while 0 <= t - lane < K, and 0 otherwise.
    """
    a = np.asarray(a, dtype=np.int64)
    b = np.asarray(b, dtype=np.int64)
    n_rows, k = a.shape
    n_cols = b.shape[1]
    a_left = [int(a[i, t - i]) if 0 <= t - i < k else 0 for i in range(n_rows)]
    b_top = [int(b[t - j, j]) if 0 <= t - j < k else 0 for j in range(n_cols)]
    return a_left, b_top


def simulate_output_stationary(a, b, data_w=DATA_W, acc_w=ACC_W, trace=None):
    """Cycle-level model of the output-stationary array.

    Each PE (i, j) has two forwarding registers and an accumulator, exactly
    as in spec section 6.2. All registers start at zero (the CLEAR state).
    In every step the PE reads a_in from its left neighbour's a_out (or the
    a_left edge) and b_in from its upper neighbour's b_out (or the b_top
    edge), then at the clock edge updates:

        acc <= acc + a_in * b_in;  a_out <= a_in;  b_out <= b_in

    Returns ``(C, T)``. If ``trace`` is a list, one entry per step is appended
    with the operand pair each PE multiplied, which is handy when comparing
    against a waveform.
    """
    a = check_operand(a, data_w, "A")
    b = check_operand(b, data_w, "B")
    n_rows, k = a.shape
    if b.shape[0] != k:
        raise ValueError(f"inner dimensions differ: A is {a.shape}, B is {b.shape}")
    n_cols = b.shape[1]
    steps = k + n_rows + n_cols - 2  # K + 2N - 2 when the array is square

    a_out = np.zeros((n_rows, n_cols), dtype=np.int64)
    b_out = np.zeros((n_rows, n_cols), dtype=np.int64)
    acc = np.zeros((n_rows, n_cols), dtype=np.int64)

    for t in range(steps):
        a_left, b_top = edge_inputs(a, b, t)
        # Inputs are read from the registers as they were before this edge,
        # which is what non-blocking assignments do in the RTL.
        a_in = np.empty_like(a_out)
        b_in = np.empty_like(b_out)
        a_in[:, 0] = a_left
        a_in[:, 1:] = a_out[:, :-1]
        b_in[0, :] = b_top
        b_in[1:, :] = b_out[:-1, :]

        if trace is not None:
            trace.append({"step": t, "a_in": a_in.copy(), "b_in": b_in.copy()})

        acc = acc + a_in * b_in
        a_out = a_in
        b_out = b_in

    return check_result(acc, acc_w), steps


def to_hex(value, width):
    """Two's complement hex of ``value`` in ``width`` bits, zero-padded to
    width / 4 digits, as $readmemh expects (spec section 9)."""
    if width % 4:
        raise ValueError(f"width {width} is not a whole number of hex digits")
    lo, hi = signed_range(width)
    value = int(value)
    if not lo <= value <= hi:
        raise ValueError(f"{value} does not fit in {width} signed bits")
    return f"{value & ((1 << width) - 1):0{width // 4}x}"


def from_hex(text, width):
    """Inverse of ``to_hex``: read a two's complement hex string as signed."""
    value = int(text, 16)
    if value >> (width - 1):
        value -= 1 << width
    return value
