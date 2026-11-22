"""Golden reference model for the systolic-array accelerator (issues #14, #72).

Two independent models of C = A x B, both following docs/spec.md:

* ``matmul`` is the plain mathematical reference. Every expected value in the
  test vectors comes from it.
* ``simulate_output_stationary`` steps an N x N output-stationary array one
  cycle at a time, with the same input skew and forwarding registers as the
  RTL (spec sections 6.2 to 6.4 and 7.1). It is a second opinion on the
  timing contract: it must agree with ``matmul`` after exactly
  T = k_len + 2N - 2 steps.

Phase 2 (issue #72, spec v2) adds a run-time inner length ``k_len``,
accumulate runs and tiling of products larger than the array:

* ``simulate_output_stationary`` takes N x k_len and k_len x N operands, and
  ``acc_init`` models an accumulate run (spec 7.5 and 7.6).
* ``plan_tiles`` and ``tiled_matmul`` follow the host procedure of spec
  section 12: N x N output tiles, chunks of at most K_MAX, zero padding, and
  the accumulators expected after every run.
* ``simulate_tiled`` replays those runs on the cycle-level model.

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
    """Compute cycles T = k_len + 2N - 2 (spec section 7.1). ``k`` is the
    run's k_len; it defaults to N, the Phase 1 case."""
    k = n if k is None else k
    return k + 2 * n - 2


def busy_cycles(n, k=None, accumulate=False):
    """Cycles with busy high, start to done (spec 7.4 and 7.6).

    A normal run adds CLEAR and CAPTURE to T: k_len + 2N. An accumulate run
    skips CLEAR: k_len + 2N - 1.
    """
    return compute_cycles(n, k) + (1 if accumulate else 2)


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


def simulate_output_stationary(a, b, data_w=DATA_W, acc_w=ACC_W, trace=None,
                               acc_init=None):
    """Cycle-level model of the output-stationary array.

    Each PE (i, j) has two forwarding registers and an accumulator, exactly
    as in spec section 6.2. In every step the PE reads a_in from its left
    neighbour's a_out (or the a_left edge) and b_in from its upper
    neighbour's b_out (or the b_top edge), then at the clock edge updates:

        acc <= acc + a_in * b_in;  a_out <= a_in;  b_out <= b_in

    ``a`` is N x k_len and ``b`` is k_len x N, so one function covers every
    inner length; the run takes k_len + 2N - 2 steps.

    ``acc_init`` selects the kind of run (spec 7.5). ``None`` is a normal
    run: CLEAR zeroes every accumulator first. A matrix is an accumulate
    run: CLEAR is skipped and the run adds onto these values, which are the
    C of the previous run. The forwarding registers start at zero in both
    cases, because the previous run's last step forwarded only zeros
    (spec 7.1, "Why an accumulate run can skip CLEAR").

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
    steps = k + n_rows + n_cols - 2  # k_len + 2N - 2 when the array is square

    a_out = np.zeros((n_rows, n_cols), dtype=np.int64)
    b_out = np.zeros((n_rows, n_cols), dtype=np.int64)
    if acc_init is None:
        acc = np.zeros((n_rows, n_cols), dtype=np.int64)
    else:
        acc = check_result(np.array(acc_init, dtype=np.int64), acc_w)
        if acc.shape != (n_rows, n_cols):
            raise ValueError(
                f"acc_init is {acc.shape}, but the array is {(n_rows, n_cols)}")

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


def ceil_div(x, y):
    """Smallest integer >= x / y, for positive integers."""
    return -(-x // y)


def chunk_lengths(k, k_max):
    """Split an inner dimension ``k`` into chunks of at most ``k_max``
    (spec section 12, step 2).

    Every chunk is full except possibly the last, which takes the remainder:
    K = 40 with K_MAX = 16 gives [16, 16, 8]. The last chunk needs no zero
    padding, because each run sets its own k_len.
    """
    if k < 1:
        raise ValueError(f"inner dimension must be at least 1, got {k}")
    if k_max < 1:
        raise ValueError(f"K_MAX must be at least 1, got {k_max}")
    full, rest = divmod(k, k_max)
    return [k_max] * full + ([rest] if rest else [])


def plan_tiles(m, k, p, n, k_max):
    """The runs a host makes for C = A x B, with A of size m x k and B of
    size k x p, on an N x N array (spec section 12).

    C is split into ceil(m/N) x ceil(p/N) output tiles, taken in row-major
    order, and the inner dimension into the chunks of ``chunk_lengths``.
    Every chunk of a tile runs before the next tile. Chunk 0 is a normal
    run; every later chunk is an accumulate run.

    Returns a list of dicts, one per run, with keys ``tile_row``,
    ``tile_col``, ``chunk``, ``k_start``, ``k_len`` and ``accumulate``.
    """
    for name, value in (("M", m), ("P", p), ("N", n)):
        if value < 1:
            raise ValueError(f"{name} must be at least 1, got {value}")
    lengths = chunk_lengths(k, k_max)
    runs = []
    for tile_row in range(ceil_div(m, n)):
        for tile_col in range(ceil_div(p, n)):
            k_start = 0
            for chunk, k_len in enumerate(lengths):
                runs.append({
                    "tile_row": tile_row,
                    "tile_col": tile_col,
                    "chunk": chunk,
                    "k_start": k_start,
                    "k_len": k_len,
                    "accumulate": chunk > 0,
                })
                k_start += k_len
    return runs


def pad_block(matrix, row0, rows, col0, cols):
    """The ``rows`` x ``cols`` block of ``matrix`` starting at (row0, col0),
    with zeros wherever the block runs past the edge of the matrix."""
    block = np.zeros((rows, cols), dtype=np.int64)
    part = matrix[row0:row0 + rows, col0:col0 + cols]
    block[:part.shape[0], :part.shape[1]] = part
    return block


def tiled_matmul(a, b, n, k_max, data_w=DATA_W, acc_w=ACC_W):
    """Reference for a tiled product, following ``plan_tiles``.

    Each run gets:

    * ``a``: the N x k_len block of A for its tile row and chunk, with rows
      beyond M written as zero (the padding of spec 12, step 3).
    * ``b``: the k_len x N block of B for its chunk and tile column, with
      columns beyond P written as zero.
    * ``partial``: the N x N accumulators expected after the run, the sum of
      ``matmul`` over this tile's chunks so far. After the tile's last chunk
      it is that tile of C, with zeros in the padding.

    Every expected value comes from ``matmul`` on the blocks, never from the
    cycle-level model. Returns ``(C, runs)``, where C is m x p and has been
    checked against ``matmul(a, b)`` on the whole matrices.
    """
    a = check_operand(a, data_w, "A")
    b = check_operand(b, data_w, "B")
    m, k = a.shape
    if b.shape[0] != k:
        raise ValueError(f"inner dimensions differ: A is {a.shape}, B is {b.shape}")
    p = b.shape[1]

    runs = plan_tiles(m, k, p, n, k_max)
    padded_c = np.zeros((ceil_div(m, n) * n, ceil_div(p, n) * n), dtype=np.int64)
    partial = None
    for run in runs:
        r0, c0 = run["tile_row"] * n, run["tile_col"] * n
        k0, k_len = run["k_start"], run["k_len"]
        run["a"] = pad_block(a, r0, n, k0, k_len)
        run["b"] = pad_block(b, k0, k_len, c0, n)
        product = matmul(run["a"], run["b"], data_w, acc_w)
        partial = product if not run["accumulate"] else partial + product
        run["partial"] = check_result(partial, acc_w)
        padded_c[r0:r0 + n, c0:c0 + n] = partial

    c = padded_c[:m, :p]
    if not np.array_equal(c, matmul(a, b, data_w, acc_w)):
        raise AssertionError("tiled product differs from the direct product")
    return c, runs


def simulate_tiled(runs, data_w=DATA_W, acc_w=ACC_W):
    """Replay ``runs`` from ``tiled_matmul`` on the cycle-level model.

    A normal run starts from cleared accumulators; an accumulate run starts
    from the accumulators the previous run left. Returns one
    ``(accumulators, steps)`` pair per run, to compare with the run's
    ``partial`` and with ``compute_cycles(N, k_len)``.
    """
    results = []
    acc = None
    for run in runs:
        acc, steps = simulate_output_stationary(
            run["a"], run["b"], data_w, acc_w,
            acc_init=acc if run["accumulate"] else None)
        results.append((acc, steps))
    return results


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
