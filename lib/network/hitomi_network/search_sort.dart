enum HitomiSearchSort {
  dateAdded,
  published,
  today,
  week,
  month,
  year,
  random;

  static HitomiSearchSort fromOption(String? value) =>
      values.where((sort) => sort.name == value).firstOrNull ?? dateAdded;
}
