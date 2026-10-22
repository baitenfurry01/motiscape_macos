export module sr.user_property;

import rstd.cppstd;
import sr.json;

export namespace sr
{

Json MakeUserPropertyWirePatch(std::string_view value);
Json MergeUserPropertyDescriptor(const Json& schema, const Json& patch);

} // namespace sr
