<* Growing and shrinking an owned slice by one, where an empty slice holds no allocation. *>
module crig;

<*
 Append `item` to the owned slice `*slice`, moving it into a new allocation one longer.

 @param [&inout] slice : "Owned by allocator, or empty"
 @require $Typeof(*slice)::kind == SLICE : "Expected a pointer to a slice"
*>
macro void slice_push(Allocator allocator, slice, item)
{
	usz count = slice.len;
	$Typeof(*slice) grown = alloc::new_array(allocator, $Typeof(*slice)::inner, (sz)count + 1);
	grown[count] = item;
	if (count > 0)
	{
		grown[:count] = (*slice)[..];
		alloc::free(allocator, slice.ptr);
	}
	*slice = grown;
}

<*
 Remove element `i` of the owned slice `*slice`, keeping the order; an emptied slice is freed and left `{}`.

 @param [&inout] slice : "Owned by allocator"
 @require $Typeof(*slice)::kind == SLICE : "Expected a pointer to a slice"
 @require i < slice.len : "Index out of bounds"
*>
macro void slice_remove_at(Allocator allocator, slice, usz i)
{
	usz count = slice.len;
	if (count == 1)
	{
		alloc::free(allocator, slice.ptr);
		*slice = {};
		return;
	}
	for (usz k = i; k + 1 < count; k++) (*slice)[k] = (*slice)[k + 1];
	*slice = (*slice)[:count - 1];
}
