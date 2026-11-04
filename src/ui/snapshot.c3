module crig;

<*
 Whether any field of two snapshots differs. Reads the fields from the type, so
 a new one can't be left out.
*>
macro bool fields_differ(a, b)
{
	$foreach $field : $Typeof(a)::members:
		if (a.$field != b.$field) return true;
	$endforeach
	return false;
}
