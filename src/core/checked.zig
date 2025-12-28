pub const CheckedError = error{Overflow};

pub fn add(a: usize, b: usize) CheckedError!usize {
	const res = @addWithOverflow(a, b);
	if (res[1] != 0) return error.Overflow;
	return res[0];
}
